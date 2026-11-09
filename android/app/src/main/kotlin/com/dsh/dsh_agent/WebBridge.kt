package com.dsh.dsh_agent

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 浏览器工具**原生那一路**：真实触摸、真实按键、cookie 落盘。
 *
 * ## 为什么必须有这一路
 *
 * Dart 那侧能执行 JS、能读 DOM，但有三件事它做不到：
 *
 *  1. **真实触摸**。页面里查 `event.isTrusted` 的那种站点（不少要登录、
 *     有点反自动化的站点都会查），脚本 `el.click()` 一律被当成假的。
 *     只有把 `MotionEvent` 真的投进 WebView，事件才是 trusted 的。
 *  2. **真实按键**。输入法、原生焦点相关的页面（一堆 `keydown` 监听
 *     只认真实按键）同理。
 *  3. **cookie 落盘**。平台的 cookie 库平时攒着不写，进程一被杀就丢 ——
 *     表现就是"刚才明明登录好了，重开又要登"。`CookieManager.flush()`
 *     就是干这个的，而 Dart 侧的插件没暴露它。
 *
 * ## 为什么要在视图树里找 WebView
 *
 * 插件的 Dart API 没有"派发触摸"这一项，所以我们只能拿 Activity 上
 * **真的那个 WebView 实例**。它藏在 Flutter 的 PlatformView 包装层里，
 * 因此从 `decorView` 往下找、取面积最大的那个可见 WebView ——
 * 内置浏览器页打开时就是它。
 *
 * ⚠️ **headless 页（agent 自己那页）不在这棵树里**：它没有窗口、尺寸是 0，
 * 收不到触摸。所以 `canTap` 为假时，Dart 那侧会回一句明确的
 * 「真实点击需要用户把浏览器页开着」，而不是假装点过了。
 *
 * ## 坐标换算
 *
 * Dart 给的是**页面坐标系**（CSS 像素，`getBoundingClientRect` 那一套），
 * 原生要的是**视图像素**。两者之间差一个缩放：页面自己报的
 * `window.innerWidth` 就是"这一屏有多少 CSS 像素"，所以
 * `scale = view.width / innerWidth` —— 不猜 DPI，也不用猜缩放比。
 */
class WebBridge(private val activity: MainActivity) :
    MethodChannel.MethodCallHandler {

    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 现在有没有一个**能收触摸**的 WebView
            "canTap" -> result.success(mainWebView() != null)

            "tap" -> {
                val v = mainWebView()
                if (v == null) {
                    result.success("没有可注入的页面（内置浏览器没开着）")
                    return
                }
                val err = tap(
                    v,
                    (call.argument<Double>("x") ?: 0.0),
                    (call.argument<Double>("y") ?: 0.0),
                    (call.argument<Double>("innerWidth") ?: 0.0)
                )
                result.success(err)
            }

            "swipe" -> {
                val v = mainWebView()
                if (v == null) {
                    result.success("没有可注入的页面（内置浏览器没开着）")
                    return
                }
                val err = swipe(
                    v,
                    (call.argument<Double>("fromX") ?: call.argument<Double>("x") ?: 0.0),
                    (call.argument<Double>("fromY") ?: 0.0),
                    (call.argument<Double>("toX") ?: call.argument<Double>("x") ?: 0.0),
                    (call.argument<Double>("toY") ?: 0.0),
                    (call.argument<Int>("ms") ?: 300),
                    (call.argument<Double>("innerWidth") ?: 0.0)
                )
                result.success(err)
            }

            "key" -> {
                val v = mainWebView()
                if (v == null) {
                    result.success("没有可注入的页面（内置浏览器没开着）")
                    return
                }
                result.success(key(v, call.argument<String>("key") ?: ""))
            }

            // cookie 落盘。**每次登录之后都该调一次**：
            // 不落盘的话，进程被系统杀掉时刚拿到的会话就没了。
            "flushCookies" -> {
                var ok = false
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        CookieManager.getInstance().flush()
                        ok = true
                    }
                } catch (_: Throwable) {
                    // 拿不到 cookie 管理器就算了，不影响这一轮
                }
                result.success(ok)
            }

            else -> result.notImplemented()
        }
    }

    /** 从视图树里找**面积最大的那个可见 WebView** —— 就是用户看的那一页。 */
    private fun mainWebView(): WebView? {
        val root: View = activity.window?.decorView ?: return null
        return biggest(root)
    }

    private fun biggest(v: View): WebView? {
        if (v is WebView) {
            return if (v.visibility == View.VISIBLE) v else null
        }
        if (v is ViewGroup) {
            var best: WebView? = null
            var bestArea = -1
            for (i in 0 until v.childCount) {
                val c = biggest(v.getChildAt(i)) ?: continue
                val area = c.width * c.height
                if (area > bestArea) {
                    bestArea = area
                    best = c
                }
            }
            return best
        }
        return null
    }

    /**
     * 把 CSS 坐标换算成视图坐标。
     * 返回 null = 换算成功（结果写在 out 里），否则是给模型看的错误串。
     */
    private fun toViewXY(
        v: WebView,
        cssX: Double,
        cssY: Double,
        innerWidth: Double
    ): Pair<Float, Float>? {
        val w = v.width
        val h = v.height
        // 宽高为 0 说明这一页还没布局完（或者根本不在窗口里）
        if (w <= 0 || h <= 0) return null
        val scale = if (innerWidth > 0) w / innerWidth else 1.0
        val x = (cssX * scale).toFloat()
        val y = (cssY * scale).toFloat()
        if (x < 0 || y < 0 || x > w || y > h) return null
        return Pair(x, y)
    }

    private fun tap(v: WebView, cssX: Double, cssY: Double, innerWidth: Double): String? {
        val xy = toViewXY(v, cssX, cssY, innerWidth)
            ?: return "坐标不在可点的范围内（页面可能还没布局好，或者已经滚出视口）"
        // 焦点先给这一页：有些站点的点击处理依赖"页面是活跃的"
        try {
            v.requestFocus()
        } catch (_: Throwable) {
        }
        val down = SystemClock.uptimeMillis()
        val (x, y) = xy
        // DOWN / UP 用**不同时间戳**：合成的"真实"事件里两者相隔几十毫秒，
        // 时间戳完全相同的两次事件会被一部分前端库判成异常手势。
        v.dispatchTouchEvent(
            MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0)
        )
        v.dispatchTouchEvent(
            MotionEvent.obtain(down, down + 60, MotionEvent.ACTION_UP, x, y, 0)
        )
        return null
    }

    /**
     * 一次真实滑动（手势：拖动、拖拽、懒加载页面：`window.scrollBy` 不动的地方）。
     *
     * 起点和终点**各自带 x 和 y** —— 横向列表、滑块、地图拖动都得靠它，
     * 只能竖着滑的话这三种一个都做不了。
     *
     * 用 `postDelayed` 一帧一帧插值，而不是把 MOVE 事件一次性灌进去 ——
     * 后者在页面上看起来是"瞬移"，很多滚动容器（自己处理触摸的那种）
     * 会直接忽略它。
     *
     * 坐标**夹到视图内**而不是越界就报错：拖动本来就会划到边缘
     * （从屏幕外划进来、划到屏幕外松手），越界就拒绝等于把最常见的手势
     * 全挡在门外。
     */
    private fun swipe(
        v: WebView,
        fromCssX: Double,
        fromCssY: Double,
        toCssX: Double,
        toCssY: Double,
        ms: Int,
        innerWidth: Double
    ): String? {
        val from = toViewXYClamped(v, fromCssX, fromCssY, innerWidth)
            ?: return "页面还没布局好（拿不到可操作的尺寸）"
        val to = toViewXYClamped(v, toCssX, toCssY, innerWidth)
            ?: return "页面还没布局好（拿不到可操作的尺寸）"
        val steps = maxOf(4, ms / 16)
        val t0 = SystemClock.uptimeMillis()
        v.dispatchTouchEvent(
            MotionEvent.obtain(t0, t0, MotionEvent.ACTION_DOWN, from.first, from.second, 0)
        )
        for (i in 1..steps) {
            val k = i.toFloat() / steps
            val x = from.first + (to.first - from.first) * k
            val y = from.second + (to.second - from.second) * k
            val t = t0 + (ms.toLong() * i / steps)
            val action =
                if (i == steps) MotionEvent.ACTION_UP else MotionEvent.ACTION_MOVE
            main.postDelayed({
                try {
                    v.dispatchTouchEvent(MotionEvent.obtain(t0, t, action, x, y, 0))
                } catch (_: Throwable) {
                }
            }, (ms.toLong() * i / steps))
        }
        return null
    }

    /**
     * 和 [toViewXY] 一样换算，但**越界就夹到边界**。
     *
     * 只有"这一页还没有尺寸"（宽高为 0：不在窗口里、还没布局完）
     * 才算真错误 —— 那种情况下发什么坐标都没意义。
     */
    private fun toViewXYClamped(
        v: WebView,
        cssX: Double,
        cssY: Double,
        innerWidth: Double
    ): Pair<Float, Float>? {
        val w = v.width
        val h = v.height
        if (w <= 0 || h <= 0) return null
        val scale = if (innerWidth > 0) w / innerWidth else 1.0
        val x = (cssX * scale).toFloat().coerceIn(0f, w.toFloat())
        val y = (cssY * scale).toFloat().coerceIn(0f, h.toFloat())
        return Pair(x, y)
    }

    private fun key(v: WebView, name: String): String? {
        val code = when (name.lowercase()) {
            "enter" -> KeyEvent.KEYCODE_ENTER
            "back" -> KeyEvent.KEYCODE_BACK
            "tab" -> KeyEvent.KEYCODE_TAB
            "escape", "esc" -> KeyEvent.KEYCODE_ESCAPE
            "backspace" -> KeyEvent.KEYCODE_DEL
            "delete" -> KeyEvent.KEYCODE_FORWARD_DEL
            "arrowdown", "down", "pagedown" -> KeyEvent.KEYCODE_DPAD_DOWN
            "arrowup", "up", "pageup" -> KeyEvent.KEYCODE_DPAD_UP
            "arrowleft", "left" -> KeyEvent.KEYCODE_DPAD_LEFT
            "arrowright", "right" -> KeyEvent.KEYCODE_DPAD_RIGHT
            "space" -> KeyEvent.KEYCODE_SPACE
            "home" -> KeyEvent.KEYCODE_MOVE_HOME
            "end" -> KeyEvent.KEYCODE_MOVE_END
            else -> return "不认识的按键：$name"
        }
        try {
            v.requestFocus()
        } catch (_: Throwable) {
        }
        val t = SystemClock.uptimeMillis()
        v.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
        v.dispatchKeyEvent(KeyEvent(t, t + 30, KeyEvent.ACTION_UP, code, 0))
        return null
    }
}
