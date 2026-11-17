package com.agt.tk.hwl

import android.os.Bundle
import androidx.core.view.WindowCompat
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.agt.tk.hwl.garmin.GarminBridge

class MainActivity : FlutterActivity() {

    /**
     * 让内容画到系统栏（状态栏 + 小白条）后面，实现真正的沉浸。
     *
     * `setDecorFitsSystemWindows(false)`：窗口不再为系统栏让出空间，
     * Flutter 的画面一直铺到屏幕边缘；系统栏的颜色由 AppTheme 设成透明，
     * 所以小白条区域直接显示页面底色，而不是一条不透明的色带。
     * Dart 侧的 SafeArea / MediaQuery.padding 会负责把内容避开它们。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    companion object {
        /** 系统级悬浮窗确认框的通道 */
        const val OVERLAY_CHANNEL = "dsh/overlay"

        /** 后台保活通道（前台服务 + 电池优化） */
        const val BG_CHANNEL = "dsh/bg"

        /** 打开私有目录里的文件 + 定位 */
        const val FILE_CHANNEL = "dsh/fileopen"

        /** **设备凭据**（指纹 / 面部 / PIN，由系统自己弹） */
        const val LOCK_CHANNEL = "dsh/lock"

        /** **自带的 Linux 环境**（proot + Alpine minirootfs） */
        const val LINUX_CHANNEL = "dsh/linux"

        /**
         * 浏览器工具的原生那一路：真实触摸 / 真实按键 / cookie 落盘。
         *
         * 为什么单独一条：这三件事在 Dart 侧做不到（插件没有派发触摸的
         * API，cookie 的 flush 也没暴露），而"页面查 isTrusted 就点不动"
         * 和"刚登录完重开又要登"都是它们造成的。见 WebBridge.kt。
         */
        const val WEB_CHANNEL = "dsh/web"
    }

    private var overlay: OverlayConfirm? = null
    private var activity: ActivityOverlay? = null
    private var fileBridge: FileOpenBridge? = null
    private var lockBridge: LockBridge? = null
    private var speechBridge: SpeechBridge? = null
    private var garminBridge: GarminBridge? = null

    /**
     * 设备凭据（指纹 / 面部 / PIN）和**系统语音识别界面**的结果都从这里回来。
     *
     * 两者弹的都是**独立的 Activity**，结果只能经 `onActivityResult` 传回，
     * 而且 requestCode 要和发出去的那个对上 —— 见 [LockBridge.REQ] /
     * [SpeechBridge.REQ_SYSTEM_UI]。
     */
    @Deprecated("Activity Result 旧 API：这两条流程要的都是 startActivityForResult")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: android.content.Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        lockBridge?.onActivityResult(requestCode, resultCode)
        speechBridge?.onActivityResult(requestCode, resultCode, data)
    }

    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        GarminBridge(applicationContext).also {
            garminBridge = it
            it.register(flutterEngine)
        }

        ExternalArtifactBridge(applicationContext).register(flutterEngine)

        io.flutter.plugin.common.EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ArtifactInboxEvents.CHANNEL
        ).setStreamHandler(ArtifactInboxEvents)

        val ov = OverlayConfirm(applicationContext)
        overlay = ov

        // 底部的"正在干什么"浮窗。和确认框是两个独立窗口，
        // 但都用 TYPE_APPLICATION_OVERLAY —— 同时显示会互相盖住，
        // 所以弹确认框前先把它收起来（见下面的 showConfirm）。
        val act = ActivityOverlay(applicationContext)
        activity = act

        // ChangeWhatYouThink 的 PDF 预览：Android 自带 PdfRenderer 转位图。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PdfBridge.CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                PdfBridge().handle(call, result)
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "canDraw" -> result.success(ov.canDraw())

                    "requestPermission" -> {
                        ov.requestPermission()
                        result.success(true)
                    }

                    // ---- 进度浮窗 ----
                    // 显示时机由 Dart 侧决定（应用切到后台时才显示），
                    // 原生这边只管画。
                    "showActivity" -> {
                        act.show(call.argument<String>("text") ?: "正在工作…")
                        result.success(true)
                    }

                    "updateActivity" -> {
                        // ⚠️ 这里**不能调 show()**：show 会把浮窗显示出来，
                        // 而"每一步都推一次文案"是常态 —— 于是应用内跑任务时
                        // 浮窗就冒出来了（用户报的正是这个）。
                        // 浮窗只在应用切到后台时显示，时机由 Dart 侧的生命周期决定。
                        act.update(call.argument<String>("text") ?: "正在工作…")
                        result.success(true)
                    }

                    "hideActivity" -> {
                        act.hide()
                        result.success(true)
                    }

                    "dismissActivity" -> {
                        act.dismiss()
                        result.success(true)
                    }

                    // 把应用拉回前台。
                    //
                    // 后台启动 Activity 在 Android 10+ 是被限制的，但我们
                    // **两个条件都满足**：有正在运行的前台服务，且持有
                    // SYSTEM_ALERT_WINDOW 权限。所以这里能成功。
                    //
                    // REORDER_TO_FRONT 而不是 CLEAR_TOP：前者保留已有的
                    // Activity 状态，用户回来时还停在原来的滚动位置和输入内容上。
                    "bringToFront" -> {
                        try {
                            val i = Intent(this, MainActivity::class.java).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                            }
                            startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            // 被系统拦下就算了 —— 还有通知可以点，
                            // 不能因为拉不起来就报错给用户
                            result.success(false)
                        }
                    }

                    "showConfirm" -> {
                        val title = call.argument<String>("title") ?: "操作确认"
                        val command = call.argument<String>("command") ?: ""
                        val reasons = call.argument<List<*>>("reasons")
                            ?.map { it.toString() } ?: emptyList()
                        val dangerous = call.argument<Boolean>("dangerous") ?: false

                        // MethodChannel.Result 必须且只能回一次，
                        // 悬浮窗的超时自动拒绝也走这条路径，所以这里加个闸。
                        var replied = false

                        // 确认框和进度浮窗都用 TYPE_APPLICATION_OVERLAY，
                        // 同时显示会互相遮住。确认框是**要用户立刻操作**的，
                        // 优先级更高，所以先把浮窗收起来；用户答完再放回来
                        // （act.hide 只收起、记住状态，不是销毁）。
                        act.hide()

                        // 回给 Dart 的是**三选一**的结果字符串
                        // （deny / allow / allowAll，见 OverlayConfirm）：
                        // 第三个出口是「全部运行」，布尔装不下它。
                        ov.show(title, command, reasons, dangerous) { decision ->
                            main.post {
                                if (!replied) {
                                    replied = true
                                    // 答完把浮窗放回来 —— 底层任务还在跑，
                                    // 用户仍然需要看到"在干什么"
                                    act.hide()
                                    result.success(decision)
                                }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // ---------------------------------------------------------- 打开文件 + 定位
        //
        // 打开文件**必须用 Activity 的 context**：FileProvider 和
        // startActivity 都要求有一个 Activity（弹选择器、给 URI 授权）。
        // 用 applicationContext 会在授权环节失败。
        val fb = FileOpenBridge(this)
        fileBridge = fb

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                fb.handle(call, result)
            }

        // ---------------------------------------------------------- 设备凭据（锁）
        //
        // **不用 local_auth**：那个依赖会把 BiometricPrompt 的文案、取消
        // 语义、兼容性都搬到 Dart 侧判断。系统的 `KeyguardManager` 本来就
        // 会按用户设置弹出"指纹 / 面部 / PIN"，而且**验证结果由系统保证**，
        // 应用只拿一个 true/false。
        val lockBridge = LockBridge(this)
        this.lockBridge = lockBridge
        lockBridge.attach()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCK_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                lockBridge.handle(call, result)
            }

        // ---------------------------------------------------------- 语音输入
        //
        // 系统自带的 SpeechRecognizer：不引第三方插件，口令/权限都自己处理。
        // 只有输入框旁边那颗麦克风会用到它。
        val speech = SpeechBridge(this)
        this.speechBridge = speech
        val speechChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SpeechBridge.CHANNEL,
        )
        speech.attach(speechChannel)
        speechChannel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            speech.handle(call, result)
        }

        // ---------------------------------------------------------- 自带 Linux 环境
        //
        // proot + Alpine minirootfs，零配置。
        // 首次调用 install 会把 rootfs 解到私有目录（几秒），之后直接跑命令。
        val linux = LinuxRuntime(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LINUX_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                linux.handle(call, result)
            }

        // ---------------------------------------------------------- 后台保活
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BG_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    // 有没有"忽略电池优化"。false 时 Doze 会掐掉长任务
                    "batteryIgnored" -> result.success(isIgnoringBattery())

                    // 弹系统对话框申请。这是特殊权限，只能跳系统 UI 让用户点
                    "requestBattery" -> {
                        var ok = false
                        try {
                            val i = Intent(
                                android.provider.Settings
                                    .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                            )
                            i.data = android.net.Uri.parse("package:$packageName")
                            startActivity(i)
                            ok = true
                        } catch (e: Exception) {
                            // 个别 ROM 没有这个 Activity，退回"电池优化列表"页
                            try {
                                startActivity(
                                    Intent(
                                        android.provider.Settings
                                            .ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
                                    )
                                )
                                ok = true
                            } catch (e2: Exception) {
                                ok = false
                            }
                        }
                        result.success(ok)
                    }

                    // 通知权限（Android 13+）。被拒时前台服务**仍会运行**，
                    // 只是通知不显示 —— 所以这是锦上添花，不是必需。
                    "notifEnabled" -> {
                        val ok = if (Build.VERSION.SDK_INT >= 33) {
                            checkSelfPermission("android.permission.POST_NOTIFICATIONS") ==
                                    android.content.pm.PackageManager.PERMISSION_GRANTED
                        } else true
                        result.success(ok)
                    }

                    "startService" -> {
                        val text = call.argument<String>("text") ?: "正在执行任务…"
                        AgentService.start(applicationContext, text)
                        result.success(true)
                    }

                    // ---- 发一条**独立通知**（不是那条常驻的"正在工作"）----
                    //
                    // 用途：agent 在后台完成一件事时提醒用户。和前台服务
                    // 那条通知刻意分开：那条是"我正在干活、别杀我"，
                    // 这条是"有事找你"，两者生命周期完全不同。
                    "notify" -> {
                        val title = call.argument<String>("title") ?: "Tinkung"
                        val body = call.argument<String>("body") ?: ""
                        try {
                            Notifier.post(this, title, body)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "updateService" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (text.isNotEmpty()) {
                            AgentService.update(applicationContext, text)
                        }
                        result.success(true)
                    }

                    "stopService" -> {
                        AgentService.stop(applicationContext)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        // ---------------------------------------------------------- 浏览器原生那一路
        // 真实触摸 / 真实按键 / cookie 落盘。不注册的话，页面里查
        // `event.isTrusted` 的站点永远点不动，而刚登录的会话也可能在
        // 进程被杀时丢掉 —— 而且这两件事都**不会报错**，只会"没反应"。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WEB_CHANNEL)
            .setMethodCallHandler(WebBridge(this))
    }

    /**
     * 权限请求的回调转发给 [FileOpenBridge]。
     *
     * 为什么需要这一步：`MethodChannel.Result` 是在 `configureFlutterEngine`
     * 里拿到的，而权限对话框是**异步**的（用户可能想半天才点）。
     * Result 不能跨那么久保存，所以由 Activity 在这里把结果接回来，
     * 再交给 bridge 回复。
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        fileBridge?.onPermissionResult(requestCode, grantResults)
        speechBridge?.onPermissionResult(requestCode, grantResults)
    }

    /** 有没有被加入"电池优化白名单" */
    private fun isIgnoringBattery(): Boolean {
        return try {
            val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (e: Exception) {
            // 个别 ROM 上这个 API 会抛，保守地当作"没加白名单"
            false
        }
    }

    /** 极简的 JSON 字符串转义 —— 只用于把异常信息塞进结果里 */
    private fun jsonString(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c < ' ') sb.append(" ") else sb.append(c)
            }
        }
        return sb.append("\"").toString()
    }

    override fun onDestroy() {
        overlay?.dismiss()
        overlay = null
        activity?.dismiss()
        activity = null
        speechBridge?.dispose()
        speechBridge = null
        super.onDestroy()
    }
}
