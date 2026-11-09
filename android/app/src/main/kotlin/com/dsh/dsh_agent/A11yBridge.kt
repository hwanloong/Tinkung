package com.dsh.dsh_agent

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `dsh/a11y` 通道：把 [AgentAccessibilityService] 的能力暴露给 Dart。
 *
 * 所有方法都返回 Map，**不抛异常**：无障碍没开、控件找不到、手势被系统
 * 拒绝，都要让 agent 拿到一句能执行的下一步，而不是 Dart 原始异常。
 */
class A11yBridge(private val activity: MainActivity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "dsh/a11y"
    }

    private val service: AgentAccessibilityService?
        get() = AgentAccessibilityService.instance

    private fun unavailable(): Map<String, Any?> = mapOf(
        "ok" to false,
        "code" to "NO_ACCESSIBILITY",
        "message" to
            "无障碍服务未开启。请到 设置 → 无障碍 → 已下载的服务 → PrivTasker 打开；" +
            "打开后回到应用重试。Android 13+ 若显示「受限设置」，需先在应用信息里允许。",
    )

    private fun points(raw: Any?): List<Pair<Float, Float>> {
        val list = raw as? List<*> ?: return emptyList()
        return list.mapNotNull { item ->
            val pair = item as? List<*> ?: return@mapNotNull null
            if (pair.size < 2) return@mapNotNull null
            val x = (pair[0] as? Number)?.toFloat() ?: return@mapNotNull null
            val y = (pair[1] as? Number)?.toFloat() ?: return@mapNotNull null
            Pair(x, y)
        }
    }

    private fun target(call: MethodCall): Map<String, Any?> {
        val raw = call.argument<Map<String, Any?>>("target") ?: emptyMap()
        return raw
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> {
                val s = service
                result.success(
                    mapOf(
                        "ok" to (s != null),
                        "enabled" to (s != null),
                    )
                )
            }

            "openSettings" -> {
                try {
                    val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(mapOf("ok" to true))
                } catch (e: Exception) {
                    result.success(mapOf("ok" to false, "message" to e.message))
                }
            }

            "dump" -> {
                val s = service ?: run {
                    result.success(unavailable())
                    return
                }
                val limit = call.argument<Int>("limit") ?: 120
                result.success(s.snapshot(limit))
            }

            "action" -> {
                val s = service ?: run {
                    result.success(unavailable())
                    return
                }
                val op = call.argument<String>("op").orEmpty()
                val t = target(call)
                val value = call.argument<String>("value").orEmpty()
                val backward = call.argument<Boolean>("backward") ?: false
                when (op) {
                    "click" -> s.click(t) { result.success(it) }
                    "set_text" -> s.setText(t, value) { result.success(it) }
                    "scroll" -> s.scroll(t, backward) { result.success(it) }
                    "back", "home", "recents", "notifications" ->
                        s.global(op) { result.success(it) }
                    "tap" -> {
                        val x = (t["x"] as? Number)?.toFloat()
                        val y = (t["y"] as? Number)?.toFloat()
                        if (x == null || y == null) {
                            result.success(
                                mapOf(
                                    "ok" to false,
                                    "code" to "BAD_ARG",
                                    "message" to "tap 需要 x 和 y",
                                )
                            )
                            return
                        }
                        s.tapAt(x, y) { ok ->
                            result.success(
                                mapOf("ok" to ok, "method" to "gesture_tap")
                            )
                        }
                    }
                    else -> result.success(
                        mapOf(
                            "ok" to false,
                            "code" to "BAD_ARG",
                            "message" to "未知动作：$op",
                        )
                    )
                }
            }

            "gesture" -> {
                val s = service ?: run {
                    result.success(unavailable())
                    return
                }
                val pts = points(call.arguments as? Map<*, *>)
                if (pts.size < 2) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "code" to "BAD_ARG",
                            "message" to "gesture 至少需要起点和终点",
                        )
                    )
                    return
                }
                val duration = (call.argument<Int>("duration") ?: 400).toLong()
                s.swipe(pts, duration) { ok ->
                    result.success(mapOf("ok" to ok, "method" to "accessibility_gesture"))
                }
            }

            "draw" -> {
                val s = service ?: run {
                    result.success(unavailable())
                    return
                }
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                val rawStrokes = args["strokes"] as? List<*> ?: emptyList<Any?>()
                val strokes = rawStrokes.map { points(it) }
                if (strokes.isEmpty() || strokes.any { it.size < 2 }) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "code" to "BAD_ARG",
                            "message" to "每笔至少需要两个点",
                        )
                    )
                    return
                }
                val rawDurations = args["durations"] as? List<*> ?: emptyList<Any?>()
                val durations = rawDurations.map {
                    (it as? Number)?.toLong() ?: 600L
                }
                val gap = ((args["gap"] as? Number)?.toLong() ?: 120L)
                s.drawStrokes(strokes, durations, gap) { accepted, message ->
                    result.success(
                        mapOf(
                            "ok" to (accepted > 0),
                            "accepted" to accepted,
                            "total" to strokes.size,
                            "message" to message,
                        )
                    )
                }
            }

            "launch" -> {
                val pkg = call.argument<String>("package").orEmpty()
                val intent = activity.packageManager.getLaunchIntentForPackage(pkg)
                if (intent == null) {
                    result.success(
                        mapOf(
                            "ok" to false,
                            "code" to "NO_APP",
                            "message" to "找不到可启动的应用：$pkg",
                        )
                    )
                    return
                }
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(intent)
                result.success(mapOf("ok" to true, "package" to pkg))
            }

            "openUrl" -> {
                val url = call.argument<String>("url").orEmpty()
                if (url.isBlank()) {
                    result.success(mapOf("ok" to false, "code" to "BAD_ARG"))
                    return
                }
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(mapOf("ok" to true))
                } catch (e: Exception) {
                    result.success(mapOf("ok" to false, "message" to e.message))
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun points(args: Map<*, *>?): List<Pair<Float, Float>> {
        val list = args?.get("points") as? List<*> ?: return emptyList()
        return list.mapNotNull { item ->
            val pair = item as? List<*> ?: return@mapNotNull null
            if (pair.size < 2) return@mapNotNull null
            val x = (pair[0] as? Number)?.toFloat() ?: return@mapNotNull null
            val y = (pair[1] as? Number)?.toFloat() ?: return@mapNotNull null
            Pair(x, y)
        }
    }
}
