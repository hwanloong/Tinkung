package com.dsh.dsh_agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
/**
 * PrivTasker 的无障碍通道。
 *
 * 为什么需要它：截图 + 看图猜坐标在多步任务里既贵又脆。这里直接把当前
 * 窗口的控件树交给 Dart 侧压成几十行文本，再用 rid / text / desc 做语义点击，
 * 顺带提供 `dispatchGesture`，让"在别的 App 里连续画一条曲线"成为可能。
 *
 * 这个服务**不监听具体事件内容**，只记录前台包名/窗口名；真正的读取发生在
 * Dart 调 `dump` 的时候，避免后台常驻扫描拖慢系统。
 */
class AgentAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: AgentAccessibilityService? = null
            private set
    }

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var lastPackage: String = ""

    @Volatile
    private var lastWindow: String = ""

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onInterrupt() = Unit

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        // 只要记包名/窗口名，不缓存控件 —— 读取仍然只在 Dart 调 dump 时发生。
        //
        // `TYPE_WINDOW_CONTENT_CHANGED` 也记：WebView 里的搜索框是**异步**长出来的
        // （页面脚本跑完才把 input 插进 DOM），只靠 windowStateChanged 会一直记着
        // 打开页面那一刻的 activity，排查时看起来像"树里根本没有这个框"。
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        ) {
            event.packageName?.toString()?.let { lastPackage = it }
            event.className?.toString()?.let {
                if (event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
                    lastWindow = it
                }
            }
        }
    }

    // ------------------------------------------------------------ 读取

    /**
     * 这个节点值不值得交给模型。
     *
     * ## 为什么不能只用 `isVisibleToUser`
     *
     * WebView / Compose / 部分自绘输入框会**谎报不可见**：控件明明画在屏幕上、
     * 也能点能输，`isVisibleToUser` 却是 false（真实可见的是它们外面那层
     * `WebView` 容器）。旧过滤是 `visible && (有字 || 可操作)`，于是搜索框
     * 就在这一行被整棵剪掉 —— 模型看到的是"这个页面没有输入框"。
     *
     * 所以判据改成：**有实际矩形**就够，`isVisibleToUser` 只在"没有矩形"
     * 时作为兜底；并且可编辑 / 有提示文字的节点**豁免**可见性判断。
     */
    private fun isUseful(
        node: AccessibilityNodeInfo,
        rect: Rect,
        text: String,
        desc: String,
        rid: String,
    ): Boolean {
        val hasBox = rect.width() > 0 && rect.height() > 0
        val interactive = node.isClickable || node.isEditable || node.isScrollable
        val labeled = text.isNotEmpty() || desc.isNotEmpty() || hintOf(node).isNotEmpty()
        if (!hasBox) {
            // 没有矩形还硬要显示的只有一种：输入框（它的矩形可能异步才填）。
            return node.isEditable && (labeled || node.isFocused)
        }
        // 输入框 / 有文字的控件：不必再问系统"你觉得它可见吗"。
        if (node.isEditable || labeled) return true
        if (!interactive) return rid.isNotEmpty() && node.isVisibleToUser
        return node.isVisibleToUser || interactive
    }

    /** 输入框的占位文字。空搜索框的 `text` 是空串，唯一的线索就是它。 */
    private fun hintOf(node: AccessibilityNodeInfo): String =
        node.hintText?.toString()?.trim().orEmpty()

    private fun nodeInfo(node: AccessibilityNodeInfo): Map<String, Any?> {
        val rect = Rect()
        node.getBoundsInScreen(rect)
        val fullRid = node.viewIdResourceName ?: ""
        val rid = if (fullRid.contains(":id/")) {
            "id/" + fullRid.substringAfter(":id/")
        } else {
            ""
        }
        return mapOf(
            "cls" to (node.className?.toString()?.substringAfterLast('.') ?: ""),
            "text" to (node.text?.toString()?.trim()?.take(160) ?: ""),
            "desc" to (node.contentDescription?.toString()?.trim()?.take(160) ?: ""),
            // 空输入框的唯一名字就是占位文字。没有它，模型只能说
            // "点那个没名字的输入框"，而它根本不知道哪个是搜索框。
            "hint" to hintOf(node).take(120),
            "rid" to rid,
            "clickable" to node.isClickable,
            "editable" to node.isEditable,
            "scrollable" to node.isScrollable,
            "selected" to node.isSelected,
            "focused" to node.isFocused,
            "bounds" to listOf(rect.left, rect.top, rect.right, rect.bottom),
        )
    }

    private fun collect(
        node: AccessibilityNodeInfo?,
        out: MutableList<Map<String, Any?>>,
        seen: MutableSet<String>,
        counter: IntArray,
        limit: Int,
        depth: Int,
    ) {
        if (node == null || depth > 80) return
        val rect = Rect()
        node.getBoundsInScreen(rect)
        val text = node.text?.toString()?.trim().orEmpty()
        val desc = node.contentDescription?.toString()?.trim().orEmpty()
        val rid = node.viewIdResourceName.orEmpty()

        if (isUseful(node, rect, text, desc, rid)) {
            val key = "$rid|$text|$desc|${rect.left},${rect.top},${rect.right},${rect.bottom}"
            if (seen.add(key)) {
                counter[0] += 1
                if (out.size < limit) out.add(nodeInfo(node))
            }
        }

        val count = node.childCount
        for (i in 0 until count) {
            collect(node.getChild(i), out, seen, counter, limit, depth + 1)
        }
    }

    fun snapshot(limit: Int): Map<String, Any?> {
        val root = rootInActiveWindow
        val out = mutableListOf<Map<String, Any?>>()
        val counter = intArrayOf(0)
        if (root != null) {
            collect(root, out, HashSet(), counter, limit.coerceIn(1, 200), 0)
        }
        val dm = resources.displayMetrics
        return mapOf(
            "ok" to (root != null),
            "package" to (root?.packageName?.toString() ?: lastPackage),
            "activity" to lastWindow,
            "width" to dm.widthPixels,
            "height" to dm.heightPixels,
            "nodes" to out,
            "total" to counter[0],
            "truncated" to (counter[0] > out.size),
        )
    }

    // ------------------------------------------------------------ 找节点

    private fun normalizeRid(raw: String): String {
        val s = raw.trim()
        return when {
            s.startsWith("id/") -> s.substring(3)
            s.contains(":id/") -> s.substringAfter(":id/")
            else -> s
        }
    }

    /**
     * 和 [snapshot] 用**同一套过滤规则**，保证 dump 里的 `[序号]` 与
     * `index` 目标指向同一个控件。用原始遍历序号会错位 —— 那些被过滤掉的
     * 布局容器也算在里面，模型点 `[3]` 可能点到完全不相干的地方。
     */
    private fun filteredNodes(): List<AccessibilityNodeInfo> {
        val out = mutableListOf<AccessibilityNodeInfo>()
        val seen = HashSet<String>()

        fun visit(node: AccessibilityNodeInfo?, depth: Int) {
            if (node == null || depth > 80 || out.size >= 300) return
            val rect = Rect()
            node.getBoundsInScreen(rect)
            val text = node.text?.toString()?.trim().orEmpty()
            val desc = node.contentDescription?.toString()?.trim().orEmpty()
            val rid = node.viewIdResourceName.orEmpty()
            if (isUseful(node, rect, text, desc, rid)) {
                val key = "$rid|$text|$desc|${rect.left},${rect.top},${rect.right},${rect.bottom}"
                if (seen.add(key)) out.add(node)
            }
            for (i in 0 until node.childCount) visit(node.getChild(i), depth + 1)
        }

        visit(rootInActiveWindow, 0)
        return out
    }

    private fun matchesRid(node: AccessibilityNodeInfo, rid: String): Boolean {
        val full = node.viewIdResourceName ?: return false
        val want = normalizeRid(rid)
        return full == rid || full.substringAfter(":id/") == want
    }

    /**
     * 目标解析优先级：
     * rid → text 精确 → text 包含 → desc 包含 → hint 包含 → index。
     *
     * `hint` 排在这里是必须的：搜索框**没输入内容时 text 是空串**，
     * 它唯一的名字就是占位文字（"搜索"、"Search"）。模型照着界面上的
     * 字样传 `text: "搜索"` 时，只有 hint 能命中 —— 否则它永远找不到框，
     * 也就永远输不进去。
     */
    fun findNode(target: Map<String, Any?>): AccessibilityNodeInfo? {
        val all = filteredNodes()
        if (all.isEmpty()) return null

        val rid = target["rid"]?.toString()?.trim().orEmpty()
        val text = target["text"]?.toString()?.trim().orEmpty()
        val desc = target["desc"]?.toString()?.trim().orEmpty()
        val index = (target["index"] as? Number)?.toInt() ?: -1

        if (rid.isNotEmpty()) {
            all.firstOrNull { matchesRid(it, rid) }?.let { return it }
        }
        if (text.isNotEmpty()) {
            all.firstOrNull { it.text?.toString()?.trim() == text }?.let { return it }
            all.firstOrNull {
                it.text?.toString()?.contains(text, ignoreCase = true) == true
            }?.let { return it }
        }
        if (desc.isNotEmpty()) {
            all.firstOrNull {
                it.contentDescription?.toString()?.contains(desc, ignoreCase = true) == true
            }?.let { return it }
        }
        // 占位文字：只拿来认**输入框**，避免误点到一条标题。
        all.firstOrNull {
            it.isEditable && hintOf(it).contains(text, ignoreCase = true) && text.isNotEmpty()
        }?.let { return it }
        // desc 也可能写在占位符上（WebView 的 aria-label 常落在这里）。
        all.firstOrNull {
            it.isEditable && it.contentDescription?.toString()
                ?.contains(text, ignoreCase = true) == true && text.isNotEmpty()
        }?.let { return it }
        if (index in all.indices) return all[index]
        return null
    }

    /**
     * 从 [node] 出发找一个**真能写字的**节点。
     *
     * 为什么要这一步：WebView / 自绘列表里，模型命中的常常是输入框外面那层
     * 容器（id 写在容器上、`isEditable` 在里面的 `input` 上）。直接
     * `if (!node.isEditable) return` 等于把它判死，而实际上字是能输的。
     * 这里先看自己，再往下找子节点，最后往上找父节点。
     */
    private fun editableNear(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable) return node
        // 子节点（WebView 的 input 通常在容器下面几层）
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(node)
        var guard = 0
        while (stack.isNotEmpty() && guard++ < 200) {
            val cur = stack.removeFirst()
            if (cur.isEditable) return cur
            for (i in 0 until cur.childCount) {
                cur.getChild(i)?.let { stack.add(it) }
            }
        }
        // 父节点（命中的是输入框里的文字节点时）
        var up = node.parent
        var hops = 0
        while (up != null && hops++ < 8) {
            if (up.isEditable) return up
            up = up.parent
        }
        return null
    }

    fun describe(node: AccessibilityNodeInfo?): Map<String, Any?> {
        if (node == null) return mapOf("found" to false)
        val m = nodeInfo(node).toMutableMap()
        m["found"] = true
        return m
    }

    private fun clickableAncestor(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var cur = node
        var guard = 0
        while (cur != null && guard++ < 12) {
            if (cur.isClickable) return cur
            cur = cur.parent
        }
        return null
    }

    private fun scrollableAncestor(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var cur = node
        var guard = 0
        while (cur != null && guard++ < 12) {
            if (cur.isScrollable) return cur
            cur = cur.parent
        }
        return null
    }

    private fun centerOf(node: AccessibilityNodeInfo): Pair<Float, Float> {
        val r = Rect()
        node.getBoundsInScreen(r)
        return Pair(r.exactCenterX(), r.exactCenterY())
    }

    // ------------------------------------------------------------ 动作

    fun click(target: Map<String, Any?>, onDone: (Map<String, Any?>) -> Unit) {
        val raw = findNode(target)
        if (raw == null) {
            onDone(mapOf("ok" to false, "code" to "NO_ELEMENT", "message" to "没有找到目标控件"))
            return
        }
        val node = clickableAncestor(raw) ?: raw
        node.refresh()
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        if (ok) {
            onDone(
                mapOf(
                    "ok" to true,
                    "method" to "accessibility_click",
                    "hit" to describe(node),
                )
            )
            return
        }
        // 有些自绘控件不实现 ACTION_CLICK，退回坐标点按。
        val (x, y) = centerOf(node)
        tapAt(x, y) { tapped ->
            onDone(
                mapOf(
                    "ok" to tapped,
                    "method" to "gesture_tap",
                    "hit" to describe(node),
                    "message" to if (tapped) "" else "控件不接受点击，且坐标点按失败",
                )
            )
        }
    }

    fun setText(target: Map<String, Any?>, value: String, onDone: (Map<String, Any?>) -> Unit) {
        val hit = findNode(target)
        if (hit == null) {
            onDone(mapOf("ok" to false, "code" to "NO_ELEMENT", "message" to "没有找到输入框"))
            return
        }
        // 命中的可能只是输入框外面的容器 —— 往上下找一层真正可编辑的节点。
        val node = editableNear(hit)
        if (node == null) {
            onDone(
                mapOf(
                    "ok" to false,
                    "code" to "NOT_EDITABLE",
                    "message" to "目标控件不是输入框（也没找到它里面的输入区）",
                    "hit" to describe(hit),
                )
            )
            return
        }

        // ---- 先让它真的拿到焦点 ----
        //
        // WebView 的 input 只有**聚焦**之后才接收 ACTION_SET_TEXT：不聚焦时
        // 动作会被页面吞掉，回读永远是旧值。所以这里除了 ACTION_FOCUS，
        // 还要必要时补一次坐标点击（有些实现不响应 semantic focus）。
        node.refresh()
        var focused = node.performAction(AccessibilityNodeInfo.ACTION_FOCUS) && node.isFocused
        if (!focused) {
            node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            node.refresh()
            focused = node.isFocused
        }
        if (!focused) {
            // 最后再用一次手势点中心 —— 点完等一小会儿让页面处理。
            val (cx, cy) = centerOf(node)
            tapAt(cx, cy) { /* 结果不影响后面的写入尝试 */ }
            try {
                Thread.sleep(180)
            } catch (_: InterruptedException) {
            }
            node.refresh()
        }

        // ---- 三层兜底：有些输入框就是不接受最标准的那一种 ----
        //
        // 实测 `ACTION_SET_TEXT` 在不少场景下会返回 true 但**什么都没写进去**：
        //  · WebView 里的输入框；
        //  · Flutter / Compose 这类自绘编辑框（它们只是把内容画出来）；
        //  · 带输入校验或格式化的自定义控件（金额、手机号）；
        //  · 需要先选中/清空才肯接受替换的实现。
        //
        // 所以这里按"从最标准到最像真输入"的顺序试三次，每次**回读校验**，
        // 而不是相信 performAction 的返回值。

        // ---- 1. ACTION_SET_TEXT ----
        node.refresh()
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        if (trySetText(node, value)) {
            onDone(ok("set_text", node))
            return
        }

        // ---- 2. 全选 + 粘贴 ----
        //
        // 粘贴走的是编辑框自己的 paste 通道，绕开了"只认输入法提交"的限制。
        // 先全选再粘 = 替换而不是追加。
        if (copyToClipboard(value)) {
            node.refresh()
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            // 全选（部分实现不支持这个 action，失败也不算致命）
            val sel = Bundle()
            sel.putInt(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0,
            )
            sel.putInt(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT,
                (node.text?.length ?: 0),
            )
            node.performAction(
                AccessibilityNodeInfo.ACTION_SET_SELECTION, sel,
            )
            node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            if (readsBack(node, value)) {
                onDone(ok("paste", node))
                return
            }

            // ---- 3. 先清空再粘贴 ----
            //
            // 有些控件"全选"是异步的，紧接着粘会粘到旧内容后面。
            // 先发一个清空（set_text 空串），此时通常能成功，
            // 再粘一次。
            trySetText(node, "")
            node.refresh()
            node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            if (readsBack(node, value)) {
                onDone(ok("paste_after_clear", node))
                return
            }
        }

        // 三层都不行 —— 把**每一层都试过了**这件事说清楚，
        // 让上层（Dart）去试 `input text` 那条更底层的路，
        // 而不是让模型在这里反复重试同一种写法。
        onDone(
            mapOf(
                "ok" to false,
                "code" to "SET_TEXT_REJECTED",
                "method" to "set_text+paste",
                "hit" to describe(node),
                "message" to "输入框拒绝了直接写入和粘贴（可能是自绘控件或需要输入法提交）。",
            )
        )
    }

    /** 试一次 ACTION_SET_TEXT，并用回读确认真的写进去了。 */
    private fun trySetText(node: AccessibilityNodeInfo, value: String): Boolean {
        val args = Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
            value,
        )
        val sent = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        if (!sent) return false
        // performAction 返回 true 只代表"动作被接受"，不代表内容变了。
        // 所以必须回读。空串清空时无法用"内容等于目标"判断，只认返回值。
        if (value.isEmpty()) return true
        return readsBack(node, value)
    }

    /**
     * 回读校验。
     *
     * 密码框会把内容换成圆点，所以**不能**要求完全相等 ——
     * 那种情况下只要求"长度变了 / 非空"，否则会把成功的输入判成失败，
     * 然后继续往下试粘贴，把内容弄坏。
     */
    private fun readsBack(node: AccessibilityNodeInfo, value: String): Boolean {
        node.refresh()
        val now = node.text?.toString() ?: ""
        if (now == value) return true
        if (now.contains(value)) return true
        // 密码/遮蔽场景：非空且长度接近，就当成功
        if (now.isNotEmpty() && now.length == value.length) return true
        if (node.isPassword && now.isNotEmpty()) return true
        return false
    }

    private fun ok(method: String, node: AccessibilityNodeInfo) = mapOf(
        "ok" to true,
        "method" to method,
        "hit" to describe(node),
        "message" to "",
    )

    /** 把文本放进剪贴板，供粘贴兜底用。 */
    private fun copyToClipboard(value: String): Boolean {
        return try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("dsh", value))
            true
        } catch (_: Exception) {
            false
        }
    }

    fun scroll(target: Map<String, Any?>, backward: Boolean, onDone: (Map<String, Any?>) -> Unit) {
        val raw = findNode(target) ?: rootInActiveWindow
        val node = scrollableAncestor(raw)
        if (node == null) {
            onDone(mapOf("ok" to false, "code" to "NOT_SCROLLABLE", "message" to "找不到可滚动控件"))
            return
        }
        val action = if (backward) {
            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        } else {
            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        }
        node.refresh()
        val ok = node.performAction(action)
        onDone(
            mapOf(
                "ok" to ok,
                "method" to if (backward) "scroll_backward" else "scroll_forward",
                "hit" to describe(node),
            )
        )
    }

    fun global(action: String, onDone: (Map<String, Any?>) -> Unit) {
        val id = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> -1
        }
        if (id < 0) {
            onDone(mapOf("ok" to false, "code" to "BAD_ARG", "message" to "未知全局动作：$action"))
            return
        }
        onDone(mapOf("ok" to performGlobalAction(id), "method" to "global_$action"))
    }

    // ------------------------------------------------------------ 手势

    private fun dispatch(path: Path, duration: Long, onDone: (Boolean) -> Unit) {
        val stroke = GestureDescription.StrokeDescription(path, 0L, duration.coerceIn(16L, 60000L))
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        val accepted = dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    onDone(true)
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    onDone(false)
                }
            },
            main,
        )
        if (!accepted) onDone(false)
    }

    fun tapAt(x: Float, y: Float, onDone: (Boolean) -> Unit) {
        val path = Path()
        path.moveTo(x, y)
        path.lineTo(x + 1f, y + 1f)
        dispatch(path, 40L, onDone)
    }

    /**
     * 一条连续滑动。points 是屏幕像素坐标，至少两个点。
     * steps 只影响采样密度，点之间用 lineTo 连接。
     */
    fun swipe(points: List<Pair<Float, Float>>, duration: Long, onDone: (Boolean) -> Unit) {
        if (points.size < 2) {
            onDone(false)
            return
        }
        val path = Path()
        path.moveTo(points[0].first, points[0].second)
        for (i in 1 until points.size) {
            path.lineTo(points[i].first, points[i].second)
        }
        dispatch(path, duration, onDone)
    }

    /**
     * 多笔连续绘制。每笔是一个独立的 StrokeDescription，笔与笔之间留 gap，
     * 否则绘图软件可能把两笔连成一笔。
     */
    fun drawStrokes(
        strokes: List<List<Pair<Float, Float>>>,
        durations: List<Long>,
        gapMs: Long,
        onDone: (Int, String) -> Unit,
    ) {
        var index = 0
        var accepted = 0

        fun next() {
            if (index >= strokes.size) {
                onDone(accepted, "")
                return
            }
            val stroke = strokes[index]
            if (stroke.size < 2) {
                index++
                next()
                return
            }
            val path = Path()
            path.moveTo(stroke[0].first, stroke[0].second)
            for (i in 1 until stroke.size) {
                path.lineTo(stroke[i].first, stroke[i].second)
            }
            val duration = durations.getOrElse(index) { 600L }
            dispatch(path, duration) { ok ->
                if (ok) accepted++
                index++
                main.postDelayed({ next() }, gapMs.coerceAtLeast(16L))
            }
        }

        next()
    }
}
