package com.agt.tk.hwl.garmin

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal const val GARMIN_PREFS = "garmin_bridge"
internal const val PENDING_EVENTS = "pending_events"
internal const val LEGACY_PENDING_EVENT = "pending_event"

internal object GarminEvents : EventChannel.StreamHandler {
    @Volatile var sink: EventChannel.EventSink? = null
    @Volatile var context: Context? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        GarminRelayService.flushPendingEvent()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /// Connect IQ 的回调不一定在主线程，而 `EventSink.success` 必须在主线程
    /// 调用 —— 否则平台通道会静默失败。表现正是"手表已经发了，手机端没反应"。
    ///
    /// 没有监听者时（进程还在、页面还没订阅）事件按顺序进队列，下次
    /// `onListen` 一次性补发。只存一条的话，连续两条消息会覆盖前一条。
    fun emit(context: Context, event: Map<String, Any?>) {
        main.post {
            val target = sink
            if (target != null) {
                target.success(event)
            } else {
                storePending(context, event)
            }
        }
    }

    private fun storePending(context: Context, event: Map<String, Any?>) {
        val prefs = context.getSharedPreferences(GARMIN_PREFS, Context.MODE_PRIVATE)
        val queue = try {
            org.json.JSONArray(prefs.getString(PENDING_EVENTS, "[]") ?: "[]")
        } catch (_: Exception) {
            org.json.JSONArray()
        }
        queue.put(org.json.JSONObject(event))
        // 50 条足够覆盖"应用被杀掉后手表连发几句"的情况，也不会无限吃内存。
        while (queue.length() > 50) queue.remove(0)
        prefs.edit().putString(PENDING_EVENTS, queue.toString()).apply()
    }
}

internal object GarminPushRequests {
    private val pending = ConcurrentHashMap<String, MethodChannel.Result>()
    private val main = Handler(Looper.getMainLooper())

    fun awaitResult(result: MethodChannel.Result): String {
        val id = UUID.randomUUID().toString()
        pending[id] = result
        main.postDelayed({ complete(id, false, "手表未确认接收") }, 15_000)
        return id
    }

    fun complete(id: String?, success: Boolean, error: String? = null) {
        if (id.isNullOrBlank()) return
        val result = pending.remove(id) ?: return
        main.post {
            if (success) result.success(true)
            else result.error("push_failed", error ?: "手表未确认接收", null)
        }
    }
}

class GarminBridge(context: Context) : MethodChannel.MethodCallHandler {
    private val app = context.applicationContext

    init { GarminEvents.context = app }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(GarminEvents)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                start("start")
                result.success(true)
            }
            "refresh" -> {
                start("refresh")
                result.success(true)
            }
            "select" -> {
                val id = call.argument<Number>("id")?.toLong()
                if (id == null) result.error("bad_device", "Missing Garmin device id", null)
                else {
                    start("select", id, call.argument<String>("name"))
                    result.success(true)
                }
            }
            "reply" -> {
                val text = call.argument<String>("text").orEmpty()
                val deviceId = call.argument<Number>("deviceId")?.toLong()
                val question = call.argument<String>("question")
                if (text.isBlank()) {
                    result.error("empty_message", "Message is empty", null)
                } else if (deviceId == null) {
                    result.error("bad_device", "Missing Garmin device id", null)
                } else {
                    val requestId = GarminPushRequests.awaitResult(result)
                    try {
                        start(
                            "reply",
                            id = deviceId,
                            name = call.argument<String>("deviceName"),
                            text = text,
                            question = question,
                            requestId = requestId,
                        )
                    } catch (e: Exception) {
                        GarminPushRequests.complete(requestId, false, e.message)
                    }
                }
            }
            "stop" -> {
                app.stopService(Intent(app, GarminRelayService::class.java))
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(action: String, id: Long? = null, name: String? = null, text: String? = null, question: String? = null, requestId: String? = null) {
        val intent = Intent(app, GarminRelayService::class.java).setAction(action)
        id?.let { intent.putExtra("device_id", it) }
        name?.let { intent.putExtra("device_name", it) }
        text?.let { intent.putExtra("text", it) }
        question?.let { intent.putExtra("question", it) }
        requestId?.let { intent.putExtra("request_id", it) }
        // 服务已经在跑时，从后台 startForegroundService 可能被系统限制；
        // 退回 startService（已运行的服务仍然能接收新 intent）。
        try {
            ContextCompat.startForegroundService(app, intent)
        } catch (e: Exception) {
            try {
                app.startService(intent)
            } catch (_: Exception) {
                throw e
            }
        }
    }

    companion object {
        const val CHANNEL = "dsh/garmin"
        const val EVENTS = "dsh/garmin_events"
    }
}
