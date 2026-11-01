package com.sixbit.pubsubpush

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import org.json.JSONException
import org.json.JSONObject

/**
 * Turns a bridge push into a notification:
 *   {"topic", "id", "title", "body"?, "url"?, "priority"?, "group"?}
 *   {"topic", "gap": true} when items were lost while offline.
 * Tapping opens url, if any, straight from the notification (Android 12+
 * blocks trampolines through receivers/services).
 */
object Notifier {
    private const val TAG = "pubsubpush"

    fun show(context: Context, content: ByteArray) {
        val msg = try {
            JSONObject(String(content))
        } catch (e: JSONException) {
            Log.w(TAG, "Unparseable push", e)
            return
        }
        val topic = msg.optString("topic", "?")
        val nm = context.getSystemService(NotificationManager::class.java)

        if (msg.optBoolean("gap")) {
            val channel = channel(nm, topic, "default")
            nm.notify("$topic/gap".hashCode(), Notification.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_notify)
                .setContentTitle(context.getString(R.string.gap_title, topic))
                .setContentText(context.getString(R.string.gap_text))
                .setContentIntent(openApp(context, topic.hashCode()))
                .setAutoCancel(true)
                .build())
            return
        }

        val id = msg.optString("id")
        if (id.isNotEmpty() && !Prefs(context).markSeen(topic, id)) return // duplicate

        val notifId = "$topic/$id".hashCode()
        val url = msg.optString("url").takeIf { it.isNotEmpty() }
        val body = msg.optString("body").takeIf { it.isNotEmpty() }
        val tap = url?.let {
            PendingIntent.getActivity(context, notifId,
                Intent(Intent.ACTION_VIEW, Uri.parse(it)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        } ?: openApp(context, notifId)

        val builder = Notification.Builder(context, channel(nm, topic, msg.optString("priority", "default")))
            .setSmallIcon(R.drawable.ic_notify)
            .setContentTitle(msg.optString("title", topic))
            .setSubText(topic)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setGroup(msg.optString("group").ifEmpty { topic })
        if (body != null) {
            builder.setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
        }
        nm.notify(notifId, builder.build())
    }

    /** One channel per (topic, priority), so Android's per-channel settings apply. */
    private fun channel(nm: NotificationManager, topic: String, priority: String): String {
        val (suffix, importance) = when (priority) {
            "high" -> "high" to NotificationManager.IMPORTANCE_HIGH
            "low" -> "low" to NotificationManager.IMPORTANCE_LOW
            else -> "default" to NotificationManager.IMPORTANCE_DEFAULT
        }
        val id = "topic:$topic:$suffix"
        if (nm.getNotificationChannel(id) == null) {
            val name = if (suffix == "default") topic else "$topic ($suffix)"
            nm.createNotificationChannel(NotificationChannel(id, name, importance))
        }
        return id
    }

    private fun openApp(context: Context, requestCode: Int): PendingIntent =
        PendingIntent.getActivity(context, requestCode,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}
