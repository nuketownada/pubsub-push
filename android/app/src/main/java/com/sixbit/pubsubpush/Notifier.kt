package com.sixbit.pubsubpush

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import org.json.JSONException
import org.json.JSONObject

/**
 * Turns a bridge push into a notification:
 *   {"topic", "id", "title", "body"?, "url"?, "priority"?, "group"?, "icon"?, "image"?}
 *   with "sender" and "group" (and "group_icon"?) too: a chat message, see Chats.
 *   {"topic", "id", "group", "clear": true}: remove that group's notifications.
 *   {"topic", "gap": true} when items were lost while offline.
 * Tapping opens url, if any, straight from the notification (Android 12+
 * blocks trampolines through receivers/services). icon and image are fetched
 * after the notification is shown, which is then updated without alerting.
 */
object Notifier {
    private const val TAG = "pubsubpush"
    /** Behind the (white) small icon, which is otherwise a white blob in Android 12+'s templates. */
    const val COLOR = 0xFF3B6FD4.toInt()

    fun show(context: Context, content: ByteArray) {
        val prefs = Prefs(context)
        val now = java.text.DateFormat.getTimeInstance().format(java.util.Date())
        val msg = try {
            JSONObject(String(content))
        } catch (e: JSONException) {
            Log.w(TAG, "Unparseable push", e)
            prefs.lastPush = "$now: unparseable (${content.size} bytes)"
            return
        }
        val topic = msg.optString("topic", "?")
        val nm = context.getSystemService(NotificationManager::class.java)
        prefs.lastPush = "$now: $topic" +
            if (nm.areNotificationsEnabled()) "" else " (notifications are blocked for this app)"

        if (msg.optBoolean("gap")) {
            val channel = channel(nm, topic, "default")
            nm.notify("$topic/gap".hashCode(), Notification.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_notify)
                .setColor(COLOR)
                .setContentTitle(context.getString(R.string.gap_title, topic))
                .setContentText(context.getString(R.string.gap_text))
                .setContentIntent(openApp(context, topic.hashCode()))
                .setAutoCancel(true)
                .build())
            return
        }

        val id = msg.optString("id")
        if (id.isNotEmpty() && !Prefs(context).markSeen(topic, id)) return // duplicate

        val group = msg.optString("group").ifEmpty { topic }
        if (msg.optBoolean("clear")) {
            Chats.clear(context, topic, group)
            nm.activeNotifications.filter { it.notification.group == group }.forEach { nm.cancel(it.id) }
            return
        }
        if (msg.optString("sender").isNotEmpty()) {
            Chats.add(context, topic, group, msg)
            return
        }

        val notifId = "$topic/$id".hashCode()
        val time = System.currentTimeMillis()
        nm.notify(notifId, plain(context, nm, topic, group, msg, time, null, null).build())

        val icon = msg.optString("icon").takeIf { it.isNotEmpty() }
        val image = msg.optString("image").takeIf { it.isNotEmpty() }
        if (icon != null || image != null) Thread {
            val iconBitmap = icon?.let { Images.bitmap(Images.fetch(context, it, 256)) }
            val picture = image?.let { Images.bitmap(Images.fetch(context, it, 1280)) }
            if ((iconBitmap != null || picture != null) && nm.activeNotifications.any { it.id == notifId }) {
                nm.notify(notifId, plain(context, nm, topic, group, msg, time, iconBitmap, picture)
                    .setOnlyAlertOnce(true).build())
            }
        }.start()
    }

    private fun plain(context: Context, nm: NotificationManager, topic: String, group: String, msg: JSONObject,
                      time: Long, icon: Bitmap?, picture: Bitmap?): Notification.Builder {
        val notifId = "$topic/${msg.optString("id")}".hashCode()
        val body = msg.optString("body").takeIf { it.isNotEmpty() }
        val builder = Notification.Builder(context, channel(nm, topic, msg.optString("priority", "default")))
            .setSmallIcon(R.drawable.ic_notify)
            .setColor(COLOR)
            .setContentTitle(msg.optString("title", topic))
            .setSubText(topic)
            .setContentIntent(tap(context, msg.optString("url").ifEmpty { null }, notifId))
            .setAutoCancel(true)
            .setWhen(time)
            .setShowWhen(true)
            .setGroup(group)
        if (body != null) builder.setContentText(body)
        if (icon != null) builder.setLargeIcon(icon)
        when {
            picture != null -> builder.setStyle(Notification.BigPictureStyle().bigPicture(picture)
                .also { if (body != null) it.setSummaryText(body) })
            body != null -> builder.setStyle(Notification.BigTextStyle().bigText(body))
        }
        return builder
    }

    /** Opens url straight from the notification, or this app without one. */
    fun tap(context: Context, url: String?, requestCode: Int): PendingIntent = url?.let {
        PendingIntent.getActivity(context, requestCode,
            Intent(Intent.ACTION_VIEW, Uri.parse(it)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    } ?: openApp(context, requestCode)

    /** One channel per (topic, priority), so Android's per-channel settings apply. */
    fun channel(nm: NotificationManager, topic: String, priority: String): String {
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
