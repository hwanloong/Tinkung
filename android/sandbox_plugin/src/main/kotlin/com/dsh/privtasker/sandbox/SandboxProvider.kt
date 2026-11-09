package com.dsh.privtasker.sandbox

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle

/**
 * 给 PrivTasker 调用的命令通道。
 *
 * 插件自己的 Activity 只是给用户用的终端界面；agent 走这里，
 * 不需要把用户界面切到前台。provider 受 signature 权限保护。
 */
class SandboxProvider : ContentProvider() {
    private lateinit var runtime: SandboxRuntime

    override fun onCreate(): Boolean {
        runtime = SandboxRuntime(context ?: return false)
        return true
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        return when (method) {
            "status" -> toBundle(runtime.info())
            "install" -> toBundle(runtime.install())
            "reset" -> toBundle(runtime.reset())
            "exec" -> {
                val command = extras?.getString("command") ?: ""
                if (command.isBlank()) {
                    toBundle(mapOf("ok" to false, "error" to "命令为空"))
                } else {
                    // 首次直接从 PrivTasker 走命令时，插件 Activity 可能
                    // 还没打开过；这里先补一次 rootfs 安装。
                    if (!runtime.isInstalled()) {
                        val installed = runtime.install()
                        if (installed["ok"] != true) {
                            return toBundle(installed)
                        }
                    }
                    toBundle(
                        runtime.exec(
                            command = command,
                            workdir = extras?.getString("workdir"),
                            timeoutMs = extras?.getLong("timeoutMs", 120_000L)
                                ?: 120_000L,
                            stdin = extras?.getString("stdin"),
                        ),
                    )
                }
            }
            else -> Bundle().apply {
                putBoolean("ok", false)
                putString("error", "未知方法：$method")
            }
        }
    }

    private fun toBundle(map: Map<String, Any?>): Bundle {
        return Bundle().apply {
            for ((k, v) in map) {
                when (v) {
                    null -> putString(k, null)
                    is Boolean -> putBoolean(k, v)
                    is Int -> putInt(k, v)
                    is Long -> putLong(k, v)
                    is Float -> putFloat(k, v)
                    is Double -> putDouble(k, v)
                    is String -> putString(k, v)
                    else -> putString(k, v.toString())
                }
            }
        }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
