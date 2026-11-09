package com.dsh.dsh_agent

import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Android 16 的系统 Linux Terminal（AVF 虚拟机）。
 *
 * 它不是普通第三方 App 可以读写的沙箱：终端和 Debian VM 都由
 * `com.android.virtualization.terminal` 这个系统应用管理，宿主侧没有
 * 公开的跨应用执行接口。所以这里只做检测和打开，不能诚实地说
 * “把它当成 PrivTasker 的命令后端”。
 */
class AndroidLinuxSubsystemBridge(private val ctx: Context) {
    companion object {
        const val CHANNEL = "dsh/android_linux_subsystem"
        const val PACKAGE = "com.android.virtualization.terminal"
    }

    fun status(): Map<String, Any?> {
        val installed = try {
            ctx.packageManager.getPackageInfo(PACKAGE, 0)
            true
        } catch (_: Throwable) {
            false
        }
        val launchIntent = try {
            ctx.packageManager.getLaunchIntentForPackage(PACKAGE)
        } catch (_: Throwable) {
            null
        }
        return mapOf(
            "installed" to installed,
            "launchable" to (launchIntent != null),
            "sdkInt" to Build.VERSION.SDK_INT,
            "packageName" to PACKAGE,
        )
    }

    fun launch(): Map<String, Any?> {
        return try {
            val intent = ctx.packageManager.getLaunchIntentForPackage(PACKAGE)
                ?: return mapOf(
                    "ok" to false,
                    "error" to "系统 Terminal 没有可启动的界面",
                )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: Throwable) {
            mapOf(
                "ok" to false,
                "error" to "打开系统 Linux Terminal 失败：${e.message}",
            )
        }
    }
}
