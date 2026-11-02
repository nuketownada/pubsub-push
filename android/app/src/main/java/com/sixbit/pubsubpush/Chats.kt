package com.sixbit.pubsubpush

import android.app.Notification
import android.app.NotificationManager
import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject

/**
 * Chat-style items (those with a sender): one notification per (topic, group)
 * conversation, new messages stacking up in it, like a messaging app. A
 * conversation's messages are kept only while its notification is showing:
 * once it is tapped, swiped away or cleared, the next message starts afresh.
 */
object Chats {
    private const val KEEP = 8

    private fun store(context: Context) = context.getSharedPreferences("chats", Context.MODE_PRIVATE)
    private fun key(topic: String, group: String) = "$topic\n$group"
    private fun notifId(topic: String, group: String) = "chat\n$topic\n$group".hashCode()

    private fun showing(nm: NotificationManager, id: Int) = nm.activeNotifications.any { it.id == id }

    @Synchronized
    fun add(context: Context, topic: String, group: String, msg: JSONObject) {
        val nm = context.getSystemService(NotificationManager::class.java)
        val k = key(topic, group)
        val old = if (showing(nm, notifId(topic, group))) store(context).getString(k, null) else null
        val messages = old?.let { JSONObject(it).optJSONArray("messages") } ?: JSONArray()
        val icon = msg.optString("icon").takeIf { it.isNotEmpty() }
        val image = msg.optString("image").takeIf { it.isNotEmpty() }
        val groupIcon = msg.optString("group_icon").takeIf { it.isNotEmpty() }
        messages.put(JSONObject()
            .put("sender", msg.getString("sender"))
            .put("text", msg.optString("body"))
            .put("time", System.currentTimeMillis())
            .putOpt("icon", icon)
            .putOpt("image", image))
        while (messages.length() > KEEP) messages.remove(0)
        val chat = JSONObject()
            .put("title", msg.optString("title", topic))
            .put("url", msg.optString("url"))
            .put("priority", msg.optString("priority", "default"))
            .putOpt("group_icon", groupIcon)
            .put("messages", messages)
        store(context).edit().putString(k, chat.toString()).apply()
        post(context, nm, topic, group, chat, alert = true)

        val fetch = listOfNotNull(icon?.let { it to 256 }, image?.let { it to 1280 }, groupIcon?.let { it to 256 })
            .filter { Images.cached(context, it.first) == null }
        if (fetch.isNotEmpty()) Thread {
            fetch.forEach { (url, px) -> Images.fetch(context, url, px) }
            refresh(context, topic, group)
        }.start()
    }

    /** Re-posts a conversation that is still showing, silently (e.g. its pictures arrived). */
    @Synchronized
    private fun refresh(context: Context, topic: String, group: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (!showing(nm, notifId(topic, group))) return
        val chat = store(context).getString(key(topic, group), null) ?: return
        post(context, nm, topic, group, JSONObject(chat), alert = false)
    }

    @Synchronized
    fun clear(context: Context, topic: String, group: String) {
        context.getSystemService(NotificationManager::class.java).cancel(notifId(topic, group))
        store(context).edit().remove(key(topic, group)).apply()
    }

    private fun post(context: Context, nm: NotificationManager, topic: String, group: String,
                     chat: JSONObject, alert: Boolean) {
        val title = chat.getString("title")
        val messages = chat.getJSONArray("messages")
        val last = messages.getJSONObject(messages.length() - 1)
        // A DM's title is the other person; anything else is a group conversation.
        val isGroup = (0 until messages.length()).any { messages.getJSONObject(it).getString("sender") != title }

        val style = Notification.MessagingStyle(
            Person.Builder().setName(context.getString(R.string.me)).setKey("me").build())
            .setGroupConversation(isGroup)
        if (isGroup) style.conversationTitle = title
        for (i in 0 until messages.length()) {
            val m = messages.getJSONObject(i)
            val sender = m.getString("sender")
            val person = Person.Builder().setName(sender).setKey(sender)
            Images.bitmap(Images.cached(context, m.optString("icon").ifEmpty { null }))
                ?.let { person.setIcon(Icon.createWithBitmap(it)) }
            val message = Notification.MessagingStyle.Message(m.optString("text"), m.getLong("time"), person.build())
            Images.cached(context, m.optString("image").ifEmpty { null })
                ?.let { message.setData("image/*", ImageProvider.uri(it)) }
            style.addMessage(message)
        }

        val id = notifId(topic, group)
        val builder = Notification.Builder(context, Notifier.channel(nm, topic, chat.getString("priority")))
            .setSmallIcon(R.drawable.ic_notify)
            .setColor(Notifier.COLOR)
            .setStyle(style)
            .setContentTitle(title)
            .setContentText("${last.getString("sender")}: ${last.optString("text")}")
            .setSubText(topic)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setContentIntent(Notifier.tap(context, chat.optString("url").ifEmpty { null }, id))
            .setAutoCancel(true)
            .setOnlyAlertOnce(!alert)
            .setWhen(last.getLong("time"))
            .setShowWhen(true)
        // Android lays a notification out as a conversation, with the conversation's
        // icon, only if it names a long-lived shortcut; otherwise it's a plain one
        // showing the app icon. The icon: a DM's is the sender, a group's its own, or
        // failing either the title's initial.
        val icon = Images.bitmap(Images.cached(context,
            (if (isGroup) chat.optString("group_icon") else last.optString("icon")).ifEmpty { null }))
            ?: initial(title)
        val shortcutId = "chat:$topic:$group"
        val intent = chat.optString("url").ifEmpty { null }
            ?.let { Intent(Intent.ACTION_VIEW, Uri.parse(it)) }
            ?: Intent(Intent.ACTION_MAIN).setClass(context, MainActivity::class.java)
        context.getSystemService(ShortcutManager::class.java).pushDynamicShortcut(
            ShortcutInfo.Builder(context, shortcutId)
                .setShortLabel(title)
                .setLongLived(true)
                .setIcon(Icon.createWithAdaptiveBitmap(adaptive(icon)))
                .setIntent(intent)
                .apply { if (!isGroup) setPerson(Person.Builder().setName(title).setKey(title).build()) }
                .build())
        builder.setShortcutId(shortcutId).setLargeIcon(icon)
        nm.notify(id, builder.build())
    }

    /** Pads a picture so an adaptive icon's mask (the middle 72 of 108) shows all of it. */
    private fun adaptive(picture: Bitmap): Bitmap {
        val inner = maxOf(picture.width, picture.height)
        val bitmap = Bitmap.createBitmap(inner * 3 / 2, inner * 3 / 2, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawBitmap(picture, inner / 4f + (inner - picture.width) / 2f,
            inner / 4f + (inner - picture.height) / 2f, null)
        return bitmap
    }

    /** A coloured circle with the title's first letter (skipping "#" and the like). */
    private fun initial(title: String): Bitmap {
        val size = 128
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val hue = ((title.hashCode() % 360) + 360) % 360f
        canvas.drawCircle(size / 2f, size / 2f, size / 2f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.HSVToColor(floatArrayOf(hue, 0.5f, 0.6f)) })
        val start = title.indexOfFirst { it.isLetterOrDigit() }
        val letter = if (start < 0) "?" else title.substring(start, title.offsetByCodePoints(start, 1)).uppercase()
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = size * 0.5f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        canvas.drawText(letter, size / 2f, size / 2f - (text.descent() + text.ascent()) / 2, text)
        return bitmap
    }
}
