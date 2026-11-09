package com.dsh.dsh_agent

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * 独立的「有事找你」通知。
 *
 * ## 为什么不复用 AgentService 那条
 *
 * `AgentService` 的通知是**前台服务的身份证明**：常驻、划不掉、文案是
 * "正在执行任务"。而这里要发的是"agent 在后台干完了，你来看一眼" ——
 * 它应该能划掉、应该有条数概念、点开要能回到那个会话。
 *
 * 两者混用会导致一个具体问题：一旦任务结束、服务停掉，那条通知消失，
 * 用户就永远看不到"它做完了"这件事。
 *
 * ## 为什么不带 channel id 参数
 *
 * 只有一个用途，固定一个渠道就够了。多开渠道反而让用户在系统设置里
 * 找不到"关掉哪个"。
 */
object Notifier {
    private const val CHANNEL_ID = "dsh_messages"
    private const val BASE_ID = 0x4D53 // "MS"

    fun post(ctx: Context, title: String, body: String) {
        val mgr = ctx.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(ctx, mgr)

        val open = PendingIntent.getActivity(
            ctx,
            0,
            Intent(ctx, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            // HIGH：这是"需要你注意"的事件，不是进度提示 ——
            // 该响就响，和前台服务那条 LOW 刻意不同。
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()

        // 用时间做 id：多条并存，而不是后一条覆盖前一条
        mgr.notify(BASE_ID + (System.currentTimeMillis() % 1000).toInt(), n)
    }

    private fun ensureChannel(ctx: Context, mgr: NotificationManager) {
        if (Build.VERSION.SDK_INT < 26) return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "任务提醒", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "agent 在后台完成任务时提醒" }
        )
    }
}
