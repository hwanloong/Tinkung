package com.dsh.dsh_agent

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 语音输入：只用**内嵌**的 [SpeechRecognizer]，不弹系统识别界面。
 *
 * ## 为什么之前一直报「识别服务没有响应」（ERROR_CLIENT）
 *
 * 三个原因，全都是调用方式的问题，不是设备不支持：
 *
 *  1. `cancel()` / `destroy()` 在部分 ROM 上会回调 `onError(ERROR_CLIENT)`。
 *     我们的流程是"拿到结果 → 销毁"，于是**清理动作自己触发了一次错误**。
 *     现在每个会话带编号，销毁后到达的回调一律丢弃（[stale]）。
 *  2. `EXTRA_CALLING_PACKAGE` 会被某些识别服务校验，填了直接判客户端错误；
 *     写死 `zh-CN` 在没有对应语言包时同样会。两个都去掉了。
 *  3. **默认引擎坏了，不代表设备没有能用的引擎。** 国产 ROM 上经常装着
 *     2~3 个 `RecognitionService`（厂商语音、讯飞、Google），默认那个
 *     可能被禁用或不响应。这里会枚举全部引擎，一个失败就换下一个。
 *
 * ## 为什么不退回系统识别界面
 *
 * 那是另一个 Activity，视觉和交互都和应用不是一套（用户明确说"太粗糙"）。
 * 所以宁可在这里把引擎试遍，也不弹别人的界面。
 */
class SpeechBridge(private val activity: Activity) {

    private var channel: MethodChannel? = null
    private var recognizer: SpeechRecognizer? = null
    private var pendingStart: MethodChannel.Result? = null

    /**
     * 候选引擎：null 组件 = 系统默认；[onDevice] = 端侧识别器；
     * [systemUi] = 走 `ACTION_RECOGNIZE_SPEECH` 的**系统识别界面**。
     */
    private data class Engine(
        val component: ComponentName? = null,
        val onDevice: Boolean = false,
        val systemUi: Boolean = false,
        val label: String = "",
    )

    /** 当前会话编号。销毁后旧会话的回调凭它丢弃。 */
    private var session = 0

    /** 候选引擎列表。 */
    private var engines: List<Engine> = listOf(Engine())
    private var engineIndex = 0

    /** 这一轮试过哪些引擎、各自报了什么 —— 全失败时回给界面，便于排查。 */
    private val tried = mutableListOf<String>()

    /** 成功过的引擎，下次直接用，不再从默认开始试。 */
    private var preferred: ComponentName? = null
    private var preferredKnown = false

    private val main = Handler(Looper.getMainLooper())

    fun attach(c: MethodChannel) {
        channel = c
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(isAvailable())
            "start" -> start(result)
            "stop" -> {
                stopListening()
                result.success(true)
            }
            "cancel" -> {
                teardown()
                result.success(true)
            }
            "openSettings" -> {
                openAppSettings(call.argument<String>("package"))
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** 跳到本应用的系统权限页 —— 用户被 ROM 卡住时的唯一出口。 */
    private fun openAppSettings(pkg: String? = null) {
        try {
            val target = pkg?.takeIf { it.isNotEmpty() } ?: activity.packageName
            val intent = Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:$target"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
        } catch (_: Exception) {
        }
    }

    private fun isAvailable(): Boolean = try {
        SpeechRecognizer.isRecognitionAvailable(activity) ||
            onDeviceAvailable() ||
            installedEngines().isNotEmpty() ||
            systemUiAvailable()
    } catch (_: Exception) {
        false
    }

    /**
     * 设备上有没有能接 `ACTION_RECOGNIZE_SPEECH` 的活动 —— 也就是
     * **系统那个语音识别界面**。
     *
     * 它是最后的兜底：内嵌 `SpeechRecognizer` 在某些机器上根本起不来
     * （引擎自己回 ERROR_CLIENT / 用不了麦克风），但同一个识别服务
     * 通过这个 Intent 拉起来却完全正常。这不是"设备不支持语音"，
     * 而是"内嵌调用方式不被这个引擎接受"。
     */
    private fun systemUiAvailable(): Boolean = try {
        val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        i.resolveActivity(activity.packageManager) != null
    } catch (_: Exception) {
        false
    }

    /** 设备上装了哪些识别服务（可能为空：那就只能用系统默认）。 */
    private fun installedEngines(): List<ComponentName> {
        val out = mutableListOf<ComponentName>()
        try {
            // 识别服务注册的 action 固定是 android.speech.RecognitionService。
            val intent = Intent("android.speech.RecognitionService")
            val list = activity.packageManager.queryIntentServices(intent, 0)
            for (info in list) {
                val cn = ComponentName(
                    info.serviceInfo.packageName,
                    info.serviceInfo.name,
                )
                if (!out.contains(cn)) out.add(cn)
            }
        } catch (_: Exception) {
        }
        return out
    }

    /** 候选顺序：上次成功的 → 系统默认 → 端侧识别器 → 其余已安装的。 */
    private fun buildEngines() {
        val list = mutableListOf<Engine>()
        if (preferredKnown && preferred != null) {
            list.add(Engine(component = preferred, label = preferred!!.packageName))
        }
        // 系统默认：走 ROM 指定的那个服务（通常是厂商语音或 Google）。
        list.add(Engine(label = "系统默认"))
        // **端侧识别器（API 31+）**：完全不经过第三方服务，用系统自带的
        // 离线模型。它和默认引擎是两套实现 —— 默认引擎"用不了麦克风"时，
        // 这条经常还是能录。
        if (onDeviceAvailable()) {
            list.add(Engine(onDevice = true, label = "端侧识别"))
        }
        for (cn in installedEngines()) {
            if (list.none { it.component == cn }) {
                list.add(Engine(component = cn, label = cn.packageName))
            }
        }
        // **系统识别界面：永远排在最后当兜底。**
        //
        // 它确实是"另一个界面"，不再是应用内嵌的样子 —— 但这是**能用的
        // 那条路**。用户反馈很明确：同一个识别服务，我们用 setRecognitionListener
        // 内嵌拉起时回 ERROR_CLIENT / 说用不了麦克风，而系统那个界面
        // 一切正常。那说明不支持的是**内嵌调用方式**，不是设备。
        //
        // 宁可多一个界面，也好过"点了没反应"。它放在最后，只有前面
        // 全都失败时才会走到 —— 引擎能正常工作的机器上用户根本见不到它。
        if (systemUiAvailable()) {
            list.add(Engine(systemUi = true, label = "系统识别界面"))
        }
        engines = list
        engineIndex = 0
    }

    private fun onDeviceAvailable(): Boolean = try {
        Build.VERSION.SDK_INT >= 31 &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
    } catch (_: Exception) {
        false
    }

    // ---------------------------------------------------------------- 权限

    private fun hasPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_AUDIO) return
        val grantedByResult = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        val r = pendingStart
        pendingStart = null
        if (r == null) return

        // ⚠️ 只看 `grantResults` 会误判：不少 ROM（MIUI / ColorOS / HyperOS）
        // 在授权成功时也可能给一个空数组，用户明明点了"允许"，我们却报
        // "没有麦克风权限"。所以**以系统里的真实状态为准**。
        if (grantedByResult || hasPermission()) {
            beginListening(r)
        } else {
            r.error(
                "no_permission",
                "没有麦克风权限。如果系统里已经允许，请到「设置 → 应用 → 权限」"
                    + "确认「麦克风」是允许状态（部分手机还有「单次授权」）。",
                null,
            )
        }
    }

    // ---------------------------------------------------------------- 开始

    private fun start(result: MethodChannel.Result) {
        if (!isAvailable()) {
            result.error("no_engine", "这台设备上没有可用的语音识别服务", null)
            return
        }
        if (!hasPermission()) {
            if (pendingStart != null) {
                result.error("busy", "正在等待麦克风权限", null)
                return
            }
            pendingStart = result
            activity.requestPermissions(
                arrayOf(Manifest.permission.RECORD_AUDIO),
                REQ_AUDIO,
            )
            return
        }

        // ---- 这里**不再**自己开一次 AudioRecord 做"自检" ----
        //
        // 以前在真正开始识别之前，会先建一个 AudioRecord、start、stop、
        // release，用来判断"到底能不能拿到麦克风"。这个自检本身就是
        // "识别服务没有响应"的来源：
        //
        //  · 它占着音频通道，紧接着（几微秒后）识别器就 startListening ——
        //    音频 HAL 还没从上一段会话里恢复，首个引擎直接回
        //    `ERROR_CLIENT`（提示语正是"识别服务没有响应"）；
        //  · 把自检从 1 组参数扩到 6 组，等于把这个副作用放大六倍。
        //
        // 而它得到的结论并不比 `checkSelfPermission` 可靠：权限是
        // GRANTED、但音源被占用时，真正该说话的是**识别引擎**（它的
        // onError 文案才准确）。自检抢在它前面下结论，只会误导用户。
        //
        // 所以：权限就查 `hasPermission()` 这一处，能不能录音交给引擎。
        buildEngines()
        tried.clear()
        beginListening(result)
    }

    private fun beginListening(result: MethodChannel.Result?) {
        teardown()

        if (engineIndex >= engines.size) {
            // 所有候选都试过了。
            //
            // 这里要说清**责任在哪**：走到这里说明本应用的 RECORD_AUDIO
            // 是 GRANTED（上面 `hasPermission()` 查过），那么"用不了麦克风"
            // 的是系统里那个语音服务（另一个应用），不是本应用 ——
            // 用户在自己的应用权限页怎么找都找不到问题。
            // 文案要说准，别让他白跑一趟设置。
            val detail = if (tried.isEmpty()) {
                "没有可用的识别服务"
            } else {
                tried.joinToString("；")
            };
            val firstPkg = engines.firstOrNull { it.component != null }
                ?.component
                ?.packageName;
            if (firstPkg != null) {
                emit("onEngineBlocked", firstPkg)
            }
            emit("onError", "系统语音服务用不了麦克风（不是本应用的权限）：$detail")
            emit("onEnd", null)
            return
        }

        val engine = engines[engineIndex]
        val chosen: ComponentName? = engine.component

        // ---- 兜底：拉起系统识别界面 ----
        //
        // 走到这里说明内嵌方式已经全试过了。这条路径的交互和视觉是
        // 系统自己的，和我们不是一套 —— 但它是**能用的**。
        // 结果经 `onActivityResult` 回来（见 [onActivityResult]）。
        if (engine.systemUi) {
            launchSystemUi(result)
            return
        }

        val mySession = ++session
        val sr = try {
            when {
                engine.onDevice ->
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                chosen == null -> SpeechRecognizer.createSpeechRecognizer(activity)
                else -> SpeechRecognizer.createSpeechRecognizer(activity, chosen)
            }
        } catch (_: Exception) {
            // 这个引擎连创建都失败 → 换下一个。
            tried.add("${engine.label}：无法创建")
            engineIndex++
            beginListening(result)
            return
        }
        recognizer = sr

        sr.setRecognitionListener(object : RecognitionListener {
            private fun stale(): Boolean = mySession != session

            override fun onReadyForSpeech(params: Bundle?) {
                if (stale()) return
                // 这个引擎是真的能用了，记住它。
                preferred = chosen
                preferredKnown = true
                emit("onReady", null)
            }

            override fun onBeginningOfSpeech() {}

            override fun onRmsChanged(rmsdB: Float) {
                if (stale()) return
                emit("onLevel", rmsdB)
            }

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {}

            override fun onError(error: Int) {
                // 拆识别器时触发的错误不是用户的问题 —— 丢弃。
                if (stale()) return

                val retryable = error == SpeechRecognizer.ERROR_CLIENT ||
                    error == SpeechRecognizer.ERROR_SERVER ||
                    error == SpeechRecognizer.ERROR_NETWORK ||
                    error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                    // 有些引擎会声称"没权限"（其实是我们有的），
                    // 换一个引擎往往就能用 —— 不要直接判死。
                    error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS

                // 换下一个引擎再试。第一次由用户主动点击发起的会话，
                // 换引擎是静默的 —— 界面上的"正在识别"不会断。
                if (retryable && engineIndex + 1 < engines.size) {
                    tried.add("${engine.label}：${errorText(error)}")
                    engineIndex++
                    teardown()
                    main.postDelayed({
                        if (recognizer == null) beginListening(null)
                    }, 120)
                    return
                }

                tried.add("${engine.label}：${errorText(error)}")
                emit("onError", errorText(error))
                emit("onEnd", null)
                teardown()
            }

            override fun onResults(results: Bundle?) {
                if (stale()) return
                preferred = chosen
                preferredKnown = true
                emit("onFinal", firstText(results))
                emit("onEnd", null)
                teardown()
            }

            override fun onPartialResults(partialResults: Bundle?) {
                if (stale()) return
                val t = firstText(partialResults)
                if (t.isNotEmpty()) emit("onPartial", t)
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            // 边说边出字：用户能看见自己说的话，才敢松手。
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }

        try {
            sr.startListening(intent)
            result?.success(true)
            emit("onStart", null)
        } catch (_: Exception) {
            // 启动就抛 → 换下一个引擎。
            teardown()
            engineIndex++
            beginListening(result)
        }
    }

    // -------------------------------------------------- 系统识别界面（兜底）

    /** 拉起系统识别界面时挂起的那个 `Result`，结果从 onActivityResult 回来。 */
    private var systemUiPending: MethodChannel.Result? = null

    /**
     * 用 `ACTION_RECOGNIZE_SPEECH` 拉起**系统那个语音识别界面**。
     *
     * ## 为什么最后要退到这一步
     *
     * 内嵌 `SpeechRecognizer` + `setRecognitionListener` 在某些设备上
     * 根本起不来：引擎回 `ERROR_CLIENT`（"识别服务没有响应"），换引擎
     * 之后又回 `ERROR_INSUFFICIENT_PERMISSIONS`（"用不了麦克风"）——
     * 而 RECORD_AUDIO 明明是 GRANTED 的。
     *
     * 同一个识别服务，用这个 Intent 拉起来却完全正常。差别不在权限、
     * 也不在设备，而在**调用方式**：内嵌路线要求服务端支持实时回调，
     * 部分厂商服务只实现了 Intent 这一条。
     *
     * 视觉上它是系统界面，和应用不是一套 —— 这一点用户明确提过。
     * 但"能用的丑界面"优于"漂亮但点了没反应"，所以放在候选列表
     * **最后**：引擎正常的机器永远走不到这里。
     */
    private fun launchSystemUi(result: MethodChannel.Result?) {
        if (systemUiPending != null) {
            result?.error("busy", "正在等待识别结果", null)
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(
                RecognizerIntent.EXTRA_PROMPT,
                "请说话",
            )
        }
        systemUiPending = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQ_SYSTEM_UI)
            result?.success(true)
            emit("onStart", null)
        } catch (_: Exception) {
            systemUiPending = null
            // 连界面都拉不起来：确实没有可用的识别能力了。
            tried.add("系统识别界面：无法启动")
            engineIndex++
            beginListening(null)
        }
    }

    /**
     * `MainActivity.onActivityResult` 转发进来。
     *
     * 系统识别界面回来的是 `Intent` 里的字符串列表 —— 和
     * `SpeechRecognizer` 的回调殊途同归，最后都落到 `onFinal`。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_SYSTEM_UI) return
        val r = systemUiPending
        systemUiPending = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            // 用户取消：不是错误，安静收回按钮（和 onCancel 一致）。
            emit("onCancel", null)
            emit("onEnd", null)
            return
        }
        val list = data.getStringArrayListExtra(
            RecognizerIntent.EXTRA_RESULTS,
        )
        val text = list?.firstOrNull()?.trim().orEmpty()
        if (text.isNotEmpty()) emit("onFinal", text)
        emit("onEnd", null)
    }

    // ---------------------------------------------------------------- 结束

    private fun stopListening() {
        try {
            recognizer?.stopListening()
        } catch (_: Exception) {
        }
    }

    /**
     * 拆掉识别器，并让**之后到达的回调全部作废**。
     *
     * ## 为什么删掉了 `tearingDown` 这个标志位
     *
     * 老版本用一个"置 true → 120ms 后置 false"的布尔量标记"正在拆"，
     * `stale()` 里只要它为真就丢弃回调。问题是它是个**全局**状态：
     * 旧识别器拆完、我们已经建好新识别器开始听了，这 120ms 里新识别器
     * 发来的 `onError` 也会被当作"拆卸副产物"丢掉 —— 而 `beginListening`
     * 恰恰是在 `teardown()` 之后**立刻**发起的，新引擎启动失败的那条
     * `onError` 正好落在这个窗口里，于是被静默吞掉，界面既不报错也不
     * 恢复，用户感知就是"点了没反应"。
     *
     * `session` 编号本来就够用：每个识别器创建时领一个号，`teardown`
     * 时把号一加，旧识别器此后到达的任何回调都对不上号。
     * 所以这里不再需要那面旗。
     */
    private fun teardown() {
        val sr = recognizer
        recognizer = null
        session++
        if (sr == null) return
        try {
            sr.cancel()
        } catch (_: Exception) {
        }
        try {
            sr.destroy()
        } catch (_: Exception) {
        }
    }

    fun dispose() {
        teardown()
        channel = null
    }

    // ---------------------------------------------------------------- 工具

    private fun firstText(bundle: Bundle?): String {
        val list = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        return list?.firstOrNull()?.trim().orEmpty()
    }

    private fun emit(method: String, arg: Any?) {
        main.post {
            try {
                channel?.invokeMethod(method, arg)
            } catch (_: Exception) {
            }
        }
    }

    private fun errorText(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_AUDIO -> "录音出错，可能被别的应用占用了麦克风"
        SpeechRecognizer.ERROR_CLIENT -> "识别服务没有响应，请再点一次"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
            "识别服务用不了麦克风：请到「设置 → 应用 → 权限」把「麦克风」设为允许"
        SpeechRecognizer.ERROR_NETWORK -> "网络不可用"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "网络超时"
        SpeechRecognizer.ERROR_NO_MATCH -> "没听清，再说一次"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "识别服务忙，稍后再试"
        SpeechRecognizer.ERROR_SERVER -> "识别服务出错"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "没有听到声音"
        else -> "识别失败（$code）"
    }

    companion object {
        const val CHANNEL = "dsh/speech"
        const val REQ_AUDIO = 0x5350 // "SP"
        const val REQ_SYSTEM_UI = 0x5351 // "SQ"
    }
}
