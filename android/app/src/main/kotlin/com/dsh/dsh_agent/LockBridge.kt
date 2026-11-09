package com.dsh.dsh_agent

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 弹出**系统自己的解锁界面**（指纹 / 面部 / PIN / 图案），拿一个 true/false。
 *
 * ## 为什么不用 local_auth
 *
 * `local_auth` 走的是 BiometricPrompt：文案、取消语义、设备兼容性都要在
 * Dart 侧各自处理一遍，而且**只认生物识别**，用户机器上没录指纹就直接不可用。
 *
 * `KeyguardManager.createConfirmDeviceCredentialIntent` 是系统级方案：
 *
 *  · 用户设了什么就弹什么（指纹/面部/PIN/图案），不会"没录指纹就不能用"；
 *  · **验证在系统进程里完成**，应用只拿到结果 —— 没有伪造的余地；
 *  · 零依赖，不引入 androidx.biometric。
 *
 * ## 为什么必须走 onActivityResult
 *
 * 这个流程是异步的（用户可能要试三次指纹），所以用 `pending` 记住
 * 那次请求的 result，等 `onActivityResult` 回来再回复 Dart。
 * 不这么做的话，Dart 侧的 `await` 会永远挂着。
 */
class LockBridge(private val activity: Activity) {

    private var pending: MethodChannel.Result? = null
    private var activityRef: Activity = activity

    fun attach() {
        activityRef = activity
    }

    /** 由 MainActivity 转发：Activity 换掉之后要更新引用。 */
    fun updateActivity(a: Activity) {
        activityRef = a
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(isAvailable())
            "authenticate" -> authenticate(result)
            else -> result.notImplemented()
        }
    }

    private fun km(): KeyguardManager? =
        activityRef.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager

    /** 设备上到底有没有可用的锁屏凭据。没有就别弹，直接告诉 Dart。 */
    private fun isAvailable(): Boolean {
        val k = km() ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return k.isDeviceSecure
        }
        @Suppress("DEPRECATION")
        return k.isKeyguardSecure
    }

    private fun authenticate(result: MethodChannel.Result) {
        if (!isAvailable()) {
            // 没设锁屏密码 —— 这不是错误，是"这台机器不支持"。
            result.success(false)
            return
        }
        if (pending != null) {
            // 已经有一次在等结果：别叠第二个（系统会拒绝，且 pending 会被覆盖）
            result.success(false)
            return
        }

        val k = km()
        val intent: Intent? = k?.createConfirmDeviceCredentialIntent(
            "解锁 Zeus",
            "验证身份后继续",
        )
        if (intent == null) {
            result.success(false)
            return
        }

        pending = result
        try {
            activityRef.startActivityForResult(intent, REQ)
        } catch (e: Exception) {
            pending = null
            result.error("LOCK_FAILED", e.message, null)
        }
    }

    /** MainActivity.onActivityResult 里转发进来。 */
    fun onActivityResult(requestCode: Int, resultCode: Int) {
        if (requestCode != REQ) return
        val r = pending ?: return
        pending = null
        r.success(resultCode == Activity.RESULT_OK)
    }

    companion object {
        const val REQ = 0x4C4B // "LK"
    }
}
