package com.agt.tk.hwl

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject

internal object ArtifactInboxEvents : EventChannel.StreamHandler {
    @Volatile var sink: EventChannel.EventSink? = null
    @Volatile var context: Context? = null
    private val main = Handler(Looper.getMainLooper())

    const val CHANNEL = "dsh/artifact_inbox_events"
    const val PREFS   = "artifact_inbox"
    const val KEY_PENDING = "pending_events"

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        flushPending()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

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
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val queue = try {
            org.json.JSONArray(prefs.getString(KEY_PENDING, "[]") ?: "[]")
        } catch (_: Exception) { org.json.JSONArray() }
        queue.put(JSONObject(event))
        while (queue.length() > 50) queue.remove(0)
        prefs.edit().putString(KEY_PENDING, queue.toString()).apply()
    }

    private fun flushPending() {
        val target = sink ?: return
        val ctx = context ?: return
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val queued = prefs.getString(KEY_PENDING, null) ?: return
        prefs.edit().remove(KEY_PENDING).apply()
        runCatching {
            val array = org.json.JSONArray(queued)
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val map = buildMap<String, Any?> { obj.keys().forEach { put(it, obj.get(it)) } }
                runCatching { target.success(map) }
            }
        }
    }
}
