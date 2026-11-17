# External Artifact 开发接入指南

> 让你的 Android App 成为 Tinkung 的能力扩展。

---

## 概念

**External Artifact** 是一种接入协议，允许任意 Android App 向 PrivTasker 提供自定义工具。接入后：

- AI 可以调用你 App 里的功能（读取数据、执行操作、返回结果）
- 你的 App 也可以主动向 AI 发消息，触发 AI 自动处理

通信全部走 Android 系统原生的 `ContentProvider`，不需要网络、不需要 SDK，两个 App 安装在同一台手机上即可。

---

## 快速上手（5 分钟）

### 1. 在 AndroidManifest.xml 里声明

```xml
<application ...>

    <!-- 发现锚点：让 PrivTasker 能扫描到你的 App -->
    <receiver
        android:name=".ArtifactDiscoveryReceiver"
        android:exported="true">
        <intent-filter>
            <action android:name="com.agt.tk.hwl.ARTIFACT_PROVIDER"/>
        </intent-filter>
        <meta-data
            android:name="com.agt.tk.hwl.artifact_authority"
            android:value="com.example.myapp.artifact" />
    </receiver>

    <!-- 工具提供者：AI 通过这里调用你的功能 -->
    <provider
        android:name=".ArtifactProvider"
        android:authorities="com.example.myapp.artifact"
        android:exported="true">
        <intent-filter>
            <action android:name="com.agt.tk.hwl.ARTIFACT_PROVIDER"/>
        </intent-filter>
        <meta-data
            android:name="com.agt.tk.hwl.artifact_authority"
            android:value="com.example.myapp.artifact" />
    </provider>

</application>
```

> **authority** 建议用你的包名 + `.artifact`，全局唯一即可。

---

### 2. 实现 ArtifactDiscoveryReceiver.kt

这个 Receiver 本身不处理任何广播，只是让系统能发现你的 App。

```kotlin
package com.example.myapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ArtifactDiscoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        // 不需要处理任何内容
    }
}
```

---

### 3. 实现 ArtifactProvider.kt

这是核心，实现两个方法：`list_tools` 和 `execute`。

```kotlin
package com.example.myapp

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle

class ArtifactProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        return when (method) {
            "list_tools" -> listTools()
            "execute"    -> execute(arg ?: "", extras ?: Bundle())
            else         -> Bundle().apply { putString("error", "Unknown method: $method") }
        }
    }

    // 返回工具列表（JSON 字符串）
    private fun listTools(): Bundle {
        val tools = """
        [
          {
            "name": "get_weather",
            "title": "查询天气",
            "description": "查询指定城市的当前天气",
            "params": [
              {
                "name": "city",
                "description": "城市名称，如「北京」",
                "required": true
              }
            ]
          }
        ]
        """.trimIndent()
        return Bundle().apply { putString("tools", tools) }
    }

    // 执行工具
    private fun execute(toolName: String, args: Bundle): Bundle {
        return try {
            val result = when (toolName) {
                "get_weather" -> {
                    val city = args.getString("city") ?: return Bundle().apply {
                        putString("error", "缺少参数 city")
                    }
                    getWeather(city)
                }
                else -> throw IllegalArgumentException("未知工具: $toolName")
            }
            Bundle().apply { putString("result", result) }
        } catch (e: Exception) {
            Bundle().apply { putString("error", e.message ?: "执行失败") }
        }
    }

    private fun getWeather(city: String): String {
        // 你的业务逻辑
        return "${city}：晴，22°C，东风 2 级"
    }

    // 以下方法必须实现但可以留空
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, v: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?): Int = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?): Int = 0
}
```

完成。安装你的 App 后，在 PrivTasker 设置 → External Artifact → 刷新，就能看到它，AI 随后即可调用 `get_weather`。

---

## 协议详解

### list_tools — 工具列表

PrivTasker 调用 `ContentResolver.call(uri, "list_tools", null, null)` 时，你需要返回一个 Bundle：

```
Bundle {
  "tools": "<JSON 字符串>"
}
```

JSON 结构：

```json
[
  {
    "name": "tool_id",
    "title": "显示名（给用户看的）",
    "description": "工具说明（AI 靠这个决定什么时候调用，写清楚一点）",
    "params": [
      {
        "name": "param_name",
        "description": "参数说明",
        "required": true
      }
    ]
  }
]
```

**字段说明：**

| 字段 | 必填 | 说明 |
|------|------|------|
| `name` | ✅ | 工具唯一 ID，只用字母数字下划线，不能有空格 |
| `title` | ✅ | 界面上显示的名字 |
| `description` | ✅ | AI 决定调用时机的依据，**写清楚能做什么、不能做什么** |
| `params` | — | 参数列表，没有参数时传空数组 `[]` |
| `params[].name` | ✅ | 参数名 |
| `params[].description` | ✅ | 参数说明 |
| `params[].required` | — | 是否必填，默认 true |

---

### execute — 执行工具

PrivTasker 调用 `ContentResolver.call(uri, "execute", toolName, extras)` 时：

- `arg`（第三个参数）= 工具名（即 `name` 字段）
- `extras` = 参数 Bundle，每个参数以字符串形式传入

你需要返回：

```
// 成功
Bundle { "result": "结果字符串" }

// 失败
Bundle { "error": "错误描述" }
```

**结果格式建议：**
- 返回简洁的纯文本，AI 会直接读这个结果
- 不要返回 HTML 或复杂格式
- 结果太长（超过 2000 字）AI 可能处理不好，建议截断

---

## 主动唤醒 AI（进阶）

你的 App 可以主动向 PrivTasker 推送消息，AI 收到后会自动响应。

```kotlin
fun notifyAI(context: Context, message: String) {
    try {
        val inboxUri = Uri.parse("content://com.agt.tk.hwl.artifact_inbox")
        val extras = Bundle().apply {
            putString("authority", "com.example.myapp.artifact") // 你的 authority
            putString("label", "我的 App")                       // 显示名
            putString("message", message)                        // 要说的话
            // putString("conv_id", "可选：指定复用某条会话")     // 不填则自动分配
        }
        context.contentResolver.call(inboxUri, "push", null, extras)
    } catch (e: Exception) {
        // PrivTasker 未安装或未运行时会抛异常，忽略即可
    }
}
```

调用示例：

```kotlin
// 传感器检测到异常时主动通知 AI
notifyAI(context, "检测到心率异常：当前 142bpm，持续 3 分钟，请分析")

// 任务完成后通知 AI
notifyAI(context, "文件下载完成，路径：/sdcard/Download/report.pdf，请帮我分析")
```

**效果：** PrivTasker 会建一条专属于你 App 的会话（和其他会话不会混在一起），AI 收到消息后自动处理并回复，用户打开 App 就能看到结果。

---

## 完整示例（Demo App）

项目里已有一个完整的 demo：`demo_artifact/`

包含：
- `ArtifactDiscoveryReceiver.kt` — 发现锚点
- `ArtifactProvider.kt` — 实现了 4 个工具：
  - `get_battery` — 读取电量和充电状态
  - `get_device_info` — 读取设备型号和系统版本
  - `echo` — 回声测试（用于调试）
  - `notify_ai` — 主动推送消息给 AI（演示主动唤醒）
- `AndroidManifest.xml` — 完整的声明示例

---

## 常见问题

**Q: AI 怎么知道什么时候调用我的工具？**

靠 `description` 字段。描述越具体，AI 调用越准确。推荐写法：
- 好：`"查询指定城市的实时天气，返回温度、天气状况和风力"`
- 差：`"天气工具"`

**Q: PrivTasker 刷新后看不到我的 App？**

检查：
1. `ArtifactDiscoveryReceiver` 的 `intent-filter` 是否有 `com.agt.tk.hwl.ARTIFACT_PROVIDER`
2. `ArtifactProvider` 的 `exported` 是否为 `true`
3. `meta-data` 的 `name` 是否是 `com.agt.tk.hwl.artifact_authority`
4. 安装的是最新版本（旧版 APK 可能缺少 receiver 声明）

**Q: execute 超时了怎么办？**

PrivTasker 默认超时 60 秒。建议：
- 耗时操作放到后台线程（ContentProvider.call 本来就在 Binder 线程池，可以直接阻塞）
- 超过 10 秒的操作考虑先返回"正在处理"，完成后用主动唤醒通知 AI

**Q: 参数只支持字符串吗？**

是的，所有参数通过 Bundle 以字符串形式传递。如果需要传复杂结构，序列化成 JSON 字符串再传。

**Q: 怎么调试？**

在 `execute` 里加日志：
```kotlin
android.util.Log.d("MyArtifact", "execute: tool=$toolName args=$args")
```
然后 `adb logcat -s MyArtifact` 实时查看。

---

## 安全说明

- `ContentProvider` 设置了 `exported="true"`，任何 App 都能调用你的工具，不只是 PrivTasker
- 如果你的工具涉及敏感操作，建议在 `execute` 里验证调用方包名：
```kotlin
val callerPkg = context?.contentResolver?.let {
    // 通过 Binder.getCallingUid() 检查调用方
    android.os.Binder.getCallingUid()
}
// 验证是否是 PrivTasker
```
- 或者在 Manifest 里加自定义 permission 保护 ContentProvider

---

## 接口速查

| 方向 | 调用方 | 方法 | 说明 |
|------|--------|------|------|
| AI → 你的 App | PrivTasker | `call("list_tools", null, null)` | 获取工具列表 |
| AI → 你的 App | PrivTasker | `call("execute", toolName, extras)` | 执行工具 |
| 你的 App → AI | 你的 App | `call("push", null, extras)` 到 `com.agt.tk.hwl.artifact_inbox` | 主动推送消息 |
