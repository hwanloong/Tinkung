package com.agt.tk.hwl.garmin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.agt.tk.hwl.MainActivity
import com.agt.tk.hwl.R
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import org.json.JSONObject

class GarminRelayService : Service() {
    private lateinit var iq: ConnectIQ
    private val watchApp = IQApp(APP_ID)
    private var selected: IQDevice? = null
    private val boundDevices = mutableMapOf<Long, IQDevice>()
    private val registeredDeviceIds = mutableSetOf<Long>()
    private var sdkReady = false
    private val connectedByDevice = mutableMapOf<Long, Boolean>()
    private val appInstalledByDevice = mutableMapOf<Long, Boolean?>()
    private var sdkError: String? = null

    override fun onCreate() {
        super.onCreate()
        GarminEvents.context = applicationContext
        createNotificationChannel()
        startForegroundCompat()
        publishState()
        try {
            iq = ConnectIQ.getInstance(applicationContext, ConnectIQ.IQConnectType.WIRELESS)
            iq.initialize(applicationContext, true, object : ConnectIQ.ConnectIQListener {
                override fun onSdkReady() {
                    Handler(Looper.getMainLooper()).post {
                        sdkReady = true
                        sdkError = null
                        publishState()
                        loadDevices()
                    }
                }

                override fun onInitializeError(status: ConnectIQ.IQSdkErrorStatus) {
                    Handler(Looper.getMainLooper()).post {
                        sdkError = when (status) {
                            ConnectIQ.IQSdkErrorStatus.GCM_NOT_INSTALLED -> "请先安装 Garmin Connect"
                            ConnectIQ.IQSdkErrorStatus.GCM_UPGRADE_NEEDED -> "请更新 Garmin Connect"
                            ConnectIQ.IQSdkErrorStatus.SERVICE_ERROR -> "Garmin Connect 服务不可用"
                            else -> status.name
                        }
                        publishState()
                    }
                }

                override fun onSdkShutDown() {
                    Handler(Looper.getMainLooper()).post {
                        sdkReady = false
                        connectedByDevice.keys.toList().forEach { connectedByDevice[it] = false }
                        publishState()
                    }
                }
            })
        } catch (e: Exception) {
            sdkError = e.message ?: "无法启动 Connect IQ SDK"
            publishState()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "refresh" -> loadDevices()
            "select" -> selectDevice(intent.getLongExtra("device_id", -1), intent.getStringExtra("device_name"))
            "reply" -> sendReply(
                intent.getLongExtra("device_id", -1),
                intent.getStringExtra("text").orEmpty(),
                intent.getStringExtra("request_id"),
            )
            "start", null -> {
                loadDevices()
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        boundDevices.values.forEach { device ->
            runCatching { iq.unregisterForApplicationEvents(device, watchApp) }
            runCatching { iq.unregisterForDeviceEvents(device) }
        }
        runCatching { iq.unregisterAllForEvents() }
        runCatching { iq.shutdown(applicationContext) }
        publish(mapOf("type" to "status", "running" to false, "connected" to false))
        super.onDestroy()
    }

    private fun loadDevices() {
        if (!sdkReady) return
        try {
            val devices = iq.knownDevices.orEmpty().mapNotNull { device ->
                val rawName = device.friendlyName?.trim().orEmpty()
                // 只认"目标手表"，但**不能把名字写死成一个写法**：
                // 出厂名可能是 Instinct 2 / Instinct 2X / instinct2（没有空格），
                // 用户也可能把它改成"佳明设备"。原来那条
                // `Instinct\s+2` 正则遇到 `instinct2` 会直接判成不匹配，
                // 设备列表是空的 → 不注册事件 → 手表发消息手机端收不到。
                if (!isSupportedName(rawName)) {
                    null
                } else {
                    val part = runCatching { iq.getDevicePartNumber(device) }.getOrNull()
                    mapOf(
                        "id" to device.deviceIdentifier,
                        "name" to DEVICE_NAME,
                        "rawName" to rawName,
                        "status" to (runCatching { iq.getDeviceStatus(device)?.name }.getOrNull() ?: "UNKNOWN"),
                        "partNumber" to part,
                    )
                }
            }
            publish(mapOf("type" to "devices", "devices" to devices))
            val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val savedIds = prefs.getStringSet(KEY_DEVICES, emptySet()).orEmpty()
                .mapNotNull { it.toLongOrNull() }.toMutableSet()
            val legacyId = prefs.getLong(KEY_DEVICE, -1)
            if (savedIds.isEmpty() && legacyId > 0) savedIds.add(legacyId)

            // 选哪几台：优先恢复用户绑定过的；如果一条都没恢复出来
            // （换机 / 清数据 / 手表改名），退回到"已连接的"或**任意一台**。
            //
            // **关键修复**：之前 `ifEmpty` 分支只在手表 CONNECTED 时才兜底，
            // 如果手表当时断连（蓝牙关了、休眠了、用户清了配对），
            // `connected` 是 null，`devices.firstOrNull()` 虽然取到了设备，
            // 但"只在已连接时才注册"这个心智模型是错的 —— Connect IQ SDK
            // 的 `registerForAppEvents` **无论设备当时连没连都可以注册**，
            // 只要设备在 `knownDevices` 里（配对过），后续连上时消息照样到。
            //
            // 所以这里改成：优先连接中的（体验更快），但即使全都断连，
            // 也兜底注册第一台 —— 否则表现就是"手表在发，手机端收不到"。
            val toSelect = devices.filter { info ->
                (info["id"] as? Number)?.toLong()?.let { savedIds.contains(it) } == true
            }.ifEmpty {
                // 优先选已连接的（用户很可能马上要用），但没有已连接的也没关系，
                // 取第一台：Connect IQ 会在设备下次连接时把排队的消息送过来。
                listOfNotNull(
                    devices.firstOrNull {
                        (it["status"] as? String) == IQDevice.IQDeviceStatus.CONNECTED.name
                    } ?: devices.firstOrNull()
                )
            }
            for (deviceInfo in toSelect) {
                val id = (deviceInfo["id"] as? Number)?.toLong() ?: continue
                selectDevice(id, deviceInfo["name"] as? String)
            }
        } catch (e: Exception) {
            sdkError = e.message ?: "无法读取 Garmin 设备"
            publishState()
        }
    }

    /// 系统里可能同时存在骑行码表、旧手表等设备；这里只收目标手表。
    /// 名字匹配故意宽松：空格可有可无，大小写不敏感，中文名也认。
    private fun isSupportedName(name: String): Boolean {
        if (name.isBlank()) return false
        if (name.contains("佳明")) return true
        return Regex("instinct\\s*2", RegexOption.IGNORE_CASE).containsMatchIn(name)
    }

    /// 统一显示名。空串表示"还不知道是哪台"，由调用方回退到持久化的名字。
    private fun displayNameOf(device: IQDevice?): String {
        val raw = device?.friendlyName?.trim().orEmpty()
        return when {
            raw.isEmpty() -> ""
            raw.contains("instinct", ignoreCase = true) || raw.contains("佳明") -> DEVICE_NAME
            else -> raw
        }
    }

    private fun selectDevice(id: Long, name: String?) {
        if (id <= 0) return
        val storedName = when {
            name.isNullOrBlank() -> DEVICE_NAME
            name.contains("instinct", ignoreCase = true) || name.contains("佳明") -> DEVICE_NAME
            else -> name
        }
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val savedIds = prefs.getStringSet(KEY_DEVICES, emptySet()).orEmpty().toMutableSet()
        savedIds.add(id.toString())
        prefs.edit().putStringSet(KEY_DEVICES, savedIds).putLong(KEY_DEVICE, id)
            .putString(KEY_NAME, storedName).apply()
        if (!sdkReady) return
        val device = runCatching { iq.knownDevices.orEmpty().firstOrNull { it.deviceIdentifier == id } }.getOrNull()
        if (device == null) {
            publish(mapOf("type" to "error", "message" to "找不到这台设备，请刷新设备列表"))
            return
        }
        selected = device
        boundDevices[id] = device
        connectedByDevice[id] = runCatching {
            iq.getDeviceStatus(device) == IQDevice.IQDeviceStatus.CONNECTED
        }.getOrDefault(false)
        if (registeredDeviceIds.contains(id)) {
            publishState(device)
            return
        }
        registeredDeviceIds.add(id)
        runCatching {
            iq.registerForDeviceEvents(device) { _, status ->
                connectedByDevice[id] = status == IQDevice.IQDeviceStatus.CONNECTED
                publishState(device)
            }
            iq.registerForAppEvents(device, watchApp) { _, _, message, status ->
                if (status == ConnectIQ.IQMessageStatus.SUCCESS) {
                    // Connect IQ 的回调线程不保证是主线程；统一回到主线程，
                    // 后面的 ack / 事件投递都按顺序走。
                    Handler(Looper.getMainLooper()).post { handleWatchMessage(device, message) }
                }
            }
            iq.getApplicationInfo(APP_ID, device, object : ConnectIQ.IQApplicationInfoListener {
                override fun onApplicationInfoReceived(app: IQApp) {
                    appInstalledByDevice[id] = app.status == IQApp.IQAppStatus.INSTALLED
                    publishState(device)
                }
                override fun onApplicationNotInstalled(applicationId: String) {
                    appInstalledByDevice[id] = false
                    publishState(device)
                }
            })
        }.onFailure { sdkError = it.message }
        publishState(device)
    }

    private fun handleWatchMessage(device: IQDevice, message: List<Any>) {
        // 手表端发来的是 Dictionary；Android 这层通常拿到 `listOf(map)`，
        // 但也见过前面夹着别的类型。不要只取 `firstOrNull()`，遍历找第一个
        // Map —— 否则 payload 解析失败，消息就静默丢了。
        val payload = message.firstOrNull { it is Map<*, *> } as? Map<*, *> ?: runCatching {
            val raw = message.firstOrNull { it is String } as? String ?: return
            val json = JSONObject(raw)
            buildMap<String, Any> { json.keys().forEach { put(it, json.get(it)) } }
        }.getOrNull() ?: return
        when (payload["t"]?.toString()) {
            "hello" -> send(device, mapOf(
                "t" to "state",
                "state" to if (connectedByDevice[device.deviceIdentifier] == true) "ready" else "offline",
            ))
            "ask" -> {
                val text = payload["q"]?.toString()?.trim().orEmpty()
                if (text.isNotEmpty()) {
                    val id = payload["id"] as? Number
                    if (id != null) send(device, mapOf("t" to "ack", "id" to id.toInt()))
                    publish(mapOf(
                        "type" to "ask",
                        "deviceId" to device.deviceIdentifier,
                        "deviceName" to displayNameOf(device).ifEmpty { DEVICE_NAME },
                        "text" to text,
                    ))
                }
            }
            "focus" -> {
                send(device, mapOf("t" to "focus_ok"))
                publish(mapOf("type" to "focus", "deviceId" to device.deviceIdentifier))
            }
            "sync" -> publish(mapOf("type" to "sync", "deviceId" to device.deviceIdentifier))
            "clear" -> publish(mapOf("type" to "clear", "deviceId" to device.deviceIdentifier))
        }
    }

    private fun sendReply(deviceId: Long, text: String, requestId: String?) {
        val device = boundDevices[deviceId]
        val connected = device?.let {
            runCatching { iq.getDeviceStatus(it) == IQDevice.IQDeviceStatus.CONNECTED }
                .getOrDefault(connectedByDevice[deviceId] == true)
        } == true
        if (text.isBlank() || device == null || !connected || appInstalledByDevice[deviceId] == false) {
            GarminPushRequests.complete(requestId, false, "$DEVICE_NAME 未连接或未安装对应应用")
            return
        }
        val chunks = text.chunked(260)
        sendReplyChunk(device, chunks, 0, requestId)
    }

    private fun sendReplyChunk(device: IQDevice, chunks: List<String>, index: Int, requestId: String?) {
        if (index >= chunks.size) {
            GarminPushRequests.complete(requestId, true)
            return
        }
        send(device, mapOf(
            "t" to "reply", "seq" to index, "last" to (index == chunks.lastIndex),
            "text" to chunks[index], "silent" to false,
        )) { ok ->
            when {
                !ok -> {
                    publish(mapOf("type" to "error", "message" to "向 $DEVICE_NAME 发送消息失败"))
                    GarminPushRequests.complete(requestId, false, "Connect IQ 未确认发送")
                }
                // 还有下一段：稍等一下再发，避免 BLE 队列被瞬间灌满。
                index < chunks.lastIndex -> Handler(Looper.getMainLooper()).postDelayed(
                    { sendReplyChunk(device, chunks, index + 1, requestId) },
                    80,
                )
                // **最后一段确认成功才算整条推送成功。**
                //
                // 这里原来漏了 complete(true)：最后一段回调 ok 之后既不
                // 递归也不收尾，于是 `GarminPushRequests` 只能等 15 秒超时，
                // 再把已经成功送到手表的消息报成失败。用户看到的就是
                // "手表明明收到了，手机却显示推送失败"。
                else -> GarminPushRequests.complete(requestId, true)
            }
        }
    }

    private fun send(device: IQDevice, payload: Map<String, Any>, onResult: ((Boolean) -> Unit)? = null) {
        runCatching {
            iq.sendMessage(device, watchApp, listOf(payload)) { _, _, status ->
                val ok = status == ConnectIQ.IQMessageStatus.SUCCESS
                // 回调线程不保证是主线程；后续 chunk 的顺序和 Result 都回主线程处理。
                Handler(Looper.getMainLooper()).post { onResult?.invoke(ok) }
            }
        }.onFailure {
            Handler(Looper.getMainLooper()).post { onResult?.invoke(false) }
        }
    }

    private fun publishState(device: IQDevice? = selected) {
        val id = device?.deviceIdentifier ?: -1
        publish(mapOf(
            "type" to "status", "running" to true, "sdkReady" to sdkReady,
            "deviceId" to id,
            "deviceName" to displayNameOf(device).ifEmpty {
                getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_NAME, "")
            },
            "connected" to (connectedByDevice[id] == true),
            "appInstalled" to appInstalledByDevice[id], "error" to sdkError,
        ))
    }

    private fun publish(event: Map<String, Any?>) = GarminEvents.emit(this, event)

    private fun startForegroundCompat() {
        val open = PendingIntent.getActivity(this, 10, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(DEVICE_NAME)
            .setContentText("正在等待手表消息")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(NOTIFICATION_ID, notification)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Garmin 设备连接", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    companion object {
        private const val APP_ID = "b8f4a1d27c9e4f3a8b5d6c1e9f2a7d34"

        /// 界面上统一显示的名字。手表的出厂名可能是 `instinct2`、
        /// `Instinct 2`、`Instinct 2X`……直接拿来当会话标题既乱又长，
        /// 所以支持范围内统一收成这四个字。
        internal const val DEVICE_NAME = "佳明设备"

        private const val CHANNEL = "garmin_device_link"
        private const val NOTIFICATION_ID = 84
        private const val PREFS = GARMIN_PREFS
        private const val KEY_DEVICE = "device_id"
        private const val KEY_NAME = "device_name"
        private const val KEY_DEVICES = "device_ids"

        fun flushPendingEvent() {
            val sink = GarminEvents.sink ?: return
            val app = GarminEvents.context ?: return
            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val events = mutableListOf<Map<String, Any?>>()

            val queued = prefs.getString(PENDING_EVENTS, null)
            if (queued != null) {
                prefs.edit().remove(PENDING_EVENTS).apply()
                runCatching {
                    val array = org.json.JSONArray(queued)
                    for (i in 0 until array.length()) {
                        val obj = array.optJSONObject(i) ?: continue
                        events.add(obj.keys().asSequence().associateWith { jsonToAny(obj.get(it)) })
                    }
                }
            }

            // 兼容旧版本只存一条的键（升级上来的用户可能还留着）。
            val legacy = prefs.getString(LEGACY_PENDING_EVENT, null)
            if (legacy != null) {
                prefs.edit().remove(LEGACY_PENDING_EVENT).apply()
                runCatching {
                    val obj = JSONObject(legacy)
                    events.add(obj.keys().asSequence().associateWith { jsonToAny(obj.get(it)) })
                }
            }

            events.forEach { event -> runCatching { sink.success(event) } }
        }

        /// 队列里存的是 JSON；`EventSink` 只认 Kotlin/Java 的 Map/List。
        /// 不转的话，`devices` 这种嵌套事件会带着 JSONArray 过去，编码器不认。
        private fun jsonToAny(value: Any?): Any? = when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> buildMap<String, Any?> {
                value.keys().forEach { put(it, jsonToAny(value.get(it))) }
            }
            is org.json.JSONArray -> buildList<Any?> {
                for (i in 0 until value.length()) add(jsonToAny(value.get(i)))
            }
            else -> value
        }
    }
}
