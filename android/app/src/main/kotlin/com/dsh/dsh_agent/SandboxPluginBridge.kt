package com.dsh.dsh_agent

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

/**
 * 独立沙箱插件（com.dsh.privtasker.sandbox）的安装/启动桥。
 *
 * 插件 APK 打包在主 APK 的 assets 里，点“安装”时先复制到 cache，
 * 再通过 FileProvider 交给系统 PackageInstaller。插件没有 launcher
 * activity，所以安装后桌面不会多一个图标；只能由这里显式启动。
 */
class SandboxPluginBridge(private val ctx: Context) {
    companion object {
        const val CHANNEL = "dsh/sandbox_plugin"
        const val PACKAGE = "com.dsh.privtasker.sandbox"
        const val ACTIVITY = "$PACKAGE.SandboxActivity"
        const val PROVIDER = "content://com.dsh.privtasker.sandbox.provider"
        private const val ASSET = "flutter_assets/assets/plugins/privtasker-sandbox.apk"
    }

    fun status(): Map<String, Any?> {
        val installed = try {
            ctx.packageManager.getPackageInfo(PACKAGE, 0)
            true
        } catch (_: Throwable) {
            false
        }
        val canInstall = if (Build.VERSION.SDK_INT >= 26) {
            ctx.packageManager.canRequestPackageInstalls()
        } else true
        return mapOf(
            "installed" to installed,
            "canInstall" to canInstall,
            "packageName" to PACKAGE,
        )
    }

    fun install(): Map<String, Any?> {
        return try {
            val apk = File(ctx.cacheDir, "privtasker-sandbox.apk")
            ctx.assets.open(ASSET).use { input ->
                apk.outputStream().use { output -> input.copyTo(output) }
            }

            if (Build.VERSION.SDK_INT >= 26 &&
                !ctx.packageManager.canRequestPackageInstalls()
            ) {
                openUnknownSourcesSettings()
                return mapOf(
                    "ok" to false,
                    "needsPermission" to true,
                    "error" to "需要允许 PrivTasker 安装未知应用，打开开关后再点一次安装。",
                )
            }

            val uri: Uri = FileProvider.getUriForFile(
                ctx,
                "${ctx.packageName}.fileprovider",
                apk,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(
                    uri,
                    "application/vnd.android.package-archive",
                )
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: Throwable) {
            mapOf(
                "ok" to false,
                "error" to "${e.javaClass.simpleName}: ${e.message}",
            )
        }
    }

    fun launch(): Map<String, Any?> {
        return try {
            val intent = Intent().apply {
                setClassName(PACKAGE, ACTIVITY)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: Throwable) {
            mapOf(
                "ok" to false,
                "error" to "沙箱插件还没安装，或启动失败：${e.message}",
            )
        }
    }

    fun uninstall(): Map<String, Any?> {
        return try {
            val intent = Intent(
                Intent.ACTION_DELETE,
                Uri.parse("package:$PACKAGE"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: Throwable) {
            mapOf("ok" to false, "error" to e.message)
        }
    }

    /**
     * 在独立沙箱里执行命令。放到后台线程，避免 120 秒的命令卡住主线程。
     */
    fun exec(
        command: String,
        workdir: String?,
        timeoutMs: Long,
        stdin: String?,
        done: (Map<String, Any?>) -> Unit,
    ) {
        Thread {
            val result = try {
                val extras = Bundle().apply {
                    putString("command", command)
                    if (!workdir.isNullOrBlank()) putString("workdir", workdir)
                    putLong("timeoutMs", timeoutMs)
                    if (!stdin.isNullOrEmpty()) putString("stdin", stdin)
                }
                val b = ctx.contentResolver.call(
                    Uri.parse(PROVIDER),
                    "exec",
                    null,
                    extras,
                )
                if (b == null) {
                    mapOf("ok" to false, "error" to "沙箱没有返回结果")
                } else {
                    bundleToMap(b)
                }
            } catch (e: Throwable) {
                mapOf(
                    "ok" to false,
                    "error" to "独立沙箱不可用：${e.message}",
                )
            }
            Handler(Looper.getMainLooper()).post { done(result) }
        }.start()
    }

    private fun bundleToMap(b: Bundle): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        for (key in b.keySet()) {
            out[key] = b.get(key)
        }
        return out
    }

    fun openUnknownSourcesSettings() {
        try {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${ctx.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
        } catch (_: Throwable) {
            try {
                ctx.startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (_: Throwable) {
            }
        }
    }
}
