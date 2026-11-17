package com.agt.tk.hwl

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ExternalArtifactBridge(private val context: Context) {
    companion object {
        const val CHANNEL = "dsh/external_artifact"
        const val META_KEY = "com.agt.tk.hwl.artifact_authority"
        private const val CALL_TIMEOUT_MS = 60_000L
        private const val MAX_CONCURRENT_CALLS = 2
        /// 第三方 app 在 BroadcastReceiver 上声明这个 Action，让主 app 能发现它。
        /// 主 app 的 AndroidManifest.xml <queries> 里也声明了这个 Action，
        /// 所以不需要 QUERY_ALL_PACKAGES，Android 11+ 完全合规。
        const val DISCOVERY_ACTION = "com.agt.tk.hwl.ARTIFACT_PROVIDER"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val providerExecutor = ThreadPoolExecutor(
        0,
        MAX_CONCURRENT_CALLS,
        30L,
        TimeUnit.SECONDS,
        SynchronousQueue(),
        { runnable -> Thread(runnable, "external-artifact-call") },
        ThreadPoolExecutor.AbortPolicy(),
    )

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "discover" -> {
                        runAsync(result, "discover_failed", "发现插件") { discover() }
                    }
                    "list_tools" -> {
                        val authority = call.argument<String>("authority") ?: run {
                            result.error("bad_args", "authority required", null)
                            return@setMethodCallHandler
                        }
                        runAsync(result, "list_failed", "读取插件工具") {
                            listTools(authority)
                        }
                    }
                    "execute" -> {
                        val authority = call.argument<String>("authority") ?: run {
                            result.error("bad_args", "authority required", null)
                            return@setMethodCallHandler
                        }
                        val tool = call.argument<String>("tool") ?: run {
                            result.error("bad_args", "tool required", null)
                            return@setMethodCallHandler
                        }
                        val args = call.argument<Map<String, String>>("args") ?: emptyMap()
                        runAsync(result, "execute_failed", "执行插件工具") {
                            execute(authority, tool, args)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun <T> runAsync(
        result: MethodChannel.Result,
        errorCode: String,
        operation: String,
        block: () -> T,
    ) {
        val completed = AtomicBoolean(false)
        lateinit var task: FutureTask<Unit>
        val timeout = Runnable {
            if (completed.compareAndSet(false, true)) {
                task.cancel(true)
                result.error(
                    "artifact_timeout",
                    "External Artifact $operation 超时（${CALL_TIMEOUT_MS / 1000} 秒）",
                    null,
                )
            }
        }
        task = FutureTask {
            try {
                val value = block()
                mainHandler.post {
                    if (completed.compareAndSet(false, true)) {
                        mainHandler.removeCallbacks(timeout)
                        result.success(value)
                    }
                }
            } catch (e: Exception) {
                mainHandler.post {
                    if (completed.compareAndSet(false, true)) {
                        mainHandler.removeCallbacks(timeout)
                        result.error(errorCode, e.message ?: e.javaClass.simpleName, null)
                    }
                }
            }
            Unit
        }

        mainHandler.postDelayed(timeout, CALL_TIMEOUT_MS)
        try {
            providerExecutor.execute(task)
        } catch (_: RejectedExecutionException) {
            mainHandler.removeCallbacks(timeout)
            completed.set(true)
            result.error(
                "artifact_busy",
                "External Artifact 调用通道繁忙，请稍后重试",
                null,
            )
        }
    }

    /**
     * 发现已安装的 External Artifact 提供方。
     *
     * 方案：queryIntentContentProviders
     *   - 第三方 app 的 ContentProvider 上声明 intent-filter action = DISCOVERY_ACTION
     *   - 主 app <queries> 里声明这个 action
     *   - 用 queryIntentContentProviders 查到它们，读 meta-data 拿 authority
     *   - 不需要 QUERY_ALL_PACKAGES，Android 11-17+ 均合规
     *   - 比 queryBroadcastReceivers 更稳定（高版本对 receiver 可见性限制更严）
     *
     * meta-data 读取兜底：provider info → applicationInfo → getPackageInfo 重查
     */
    private fun discover(): List<Map<String, String>> {
        val pm = context.packageManager
        val intent = Intent(DISCOVERY_ACTION)

        val providers = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentContentProviders(intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.GET_META_DATA.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentContentProviders(intent, PackageManager.GET_META_DATA)
        }

        android.util.Log.d("ArtifactBridge",
            "queryIntentContentProviders found ${providers.size} providers")

        return providers.mapNotNull { info ->
            val provInfo = info.providerInfo ?: return@mapNotNull null
            val packageName = provInfo.packageName ?: return@mapNotNull null

            android.util.Log.d("ArtifactBridge",
                "  provider pkg=$packageName authority=${provInfo.authority} " +
                "metaData=${provInfo.metaData}")

            // 优先从 provider meta-data 读 authority，兜底从 application meta-data 读
            val authority = provInfo.metaData?.getString(META_KEY)
                ?: provInfo.applicationInfo?.metaData?.getString(META_KEY)
                ?: runCatching {
                    val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(
                            (PackageManager.GET_PROVIDERS or PackageManager.GET_META_DATA).toLong()))
                    } else {
                        @Suppress("DEPRECATION")
                        pm.getPackageInfo(packageName,
                            PackageManager.GET_PROVIDERS or PackageManager.GET_META_DATA)
                    }
                    pi.providers
                        ?.firstOrNull { p -> p.metaData?.getString(META_KEY) != null }
                        ?.metaData?.getString(META_KEY)
                        ?: pi.applicationInfo?.metaData?.getString(META_KEY)
                }.getOrNull()
                // 最后兜底：直接用 provider 本身的 authority（当 meta-data 和 authority 一致时）
                ?: provInfo.authority
                ?: return@mapNotNull null

            val label = try {
                pm.getApplicationLabel(provInfo.applicationInfo).toString()
            } catch (_: Exception) { packageName }

            mapOf(
                "packageName" to packageName,
                "authority"   to authority,
                "label"       to label,
            )
        }
    }

    private fun listTools(authority: String): String {
        val uri = Uri.parse("content://$authority")
        val bundle: Bundle? = context.contentResolver.call(uri, "list_tools", null, null)
        return bundle?.getString("tools") ?: "[]"
    }

    private fun execute(authority: String, tool: String, args: Map<String, String>): Map<String, String?> {
        val uri = Uri.parse("content://$authority")
        val extras = Bundle()
        args.forEach { (k, v) -> extras.putString(k, v) }
        val bundle: Bundle? = context.contentResolver.call(uri, "execute", tool, extras)
        return mapOf(
            "result" to bundle?.getString("result"),
            "error" to bundle?.getString("error"),
        )
    }
}
