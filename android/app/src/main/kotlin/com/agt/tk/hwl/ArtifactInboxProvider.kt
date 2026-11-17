package com.agt.tk.hwl

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle

/**
 * 主 app 的 External Artifact 消息接收端。
 *
 * 第三方 artifact app 调用：
 *   context.contentResolver.call(
 *     Uri.parse("content://com.agt.tk.hwl.artifact_inbox"),
 *     "push",
 *     null,
 *     Bundle().apply {
 *       putString("authority", "com.example.myapp.artifact")  // 自己的 authority
 *       putString("label", "我的 App")                        // 显示名
 *       putString("message", "用户说了什么")                  // 消息内容
 *       putString("conv_id", "可选：指定会话 id")             // 可省略
 *     }
 *   )
 *
 * 主 app 收到后通过 ArtifactInboxEvents 推给 Flutter 侧。
 */
class ArtifactInboxProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        ArtifactInboxEvents.context = context
        return true
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        if (method != "push" || extras == null) {
            return Bundle().apply { putString("error", "method must be 'push' with extras") }
        }
        val authority = extras.getString("authority") ?: return Bundle().apply { putString("error", "authority required") }
        val label     = extras.getString("label") ?: authority
        val message   = extras.getString("message") ?: return Bundle().apply { putString("error", "message required") }
        val convId    = extras.getString("conv_id") // nullable — null = 自动按 authority 分配

        val ctx = context ?: return Bundle().apply { putString("error", "no context") }
        ArtifactInboxEvents.emit(ctx, mapOf(
            "type"      to "artifact_ask",
            "authority" to authority,
            "label"     to label,
            "message"   to message,
            "convId"    to (convId ?: ""),
        ))
        return Bundle().apply { putBoolean("ok", true) }
    }

    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, v: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?): Int = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?): Int = 0
}
