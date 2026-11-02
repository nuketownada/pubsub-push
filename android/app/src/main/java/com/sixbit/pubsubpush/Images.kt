package com.sixbit.pubsubpush

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Pictures named by an item (icon, image), fetched once and kept a few days in
 * the cache, scaled down and re-encoded so the notification never holds a
 * full-size photo. Files are named by the URL's SHA-256, which is also what
 * ImageProvider serves.
 */
object Images {
    private const val TAG = "pubsubpush"
    private const val MAX_BYTES = 20 * 1024 * 1024
    private const val KEEP_MS = 3 * 24 * 3600 * 1000L

    fun dir(context: Context) = File(context.cacheDir, "images").apply { mkdirs() }

    fun file(context: Context, url: String): File {
        val hash = MessageDigest.getInstance("SHA-256").digest(url.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(dir(context), hash)
    }

    /** The cached file for url, if it was fetched. */
    fun cached(context: Context, url: String?): File? =
        url?.let { file(context, it) }?.takeIf { it.isFile }

    /** Fetches url (blocking) into the cache, at most maxPx on a side. */
    fun fetch(context: Context, url: String, maxPx: Int): File? {
        cached(context, url)?.let { return it }
        prune(context)
        return try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            val bytes = try {
                if (conn.responseCode != 200) throw java.io.IOException("HTTP ${conn.responseCode}")
                conn.inputStream.use { input ->
                    val out = java.io.ByteArrayOutputStream()
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        if (out.size() > MAX_BYTES) throw java.io.IOException("too large")
                    }
                    out.toByteArray()
                }
            } finally {
                conn.disconnect()
            }
            val bitmap = decode(bytes, maxPx) ?: throw java.io.IOException("not an image")
            val target = file(context, url)
            val tmp = File(target.path + ".tmp")
            tmp.outputStream().use {
                if (bitmap.hasAlpha()) bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
                else bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it)
            }
            tmp.renameTo(target)
            target
        } catch (e: Exception) {
            Log.w(TAG, "Couldn't fetch $url", e)
            null
        }
    }

    fun bitmap(file: File?): Bitmap? = file?.let { BitmapFactory.decodeFile(it.path) }

    private fun decode(bytes: ByteArray, maxPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPx) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val scale = maxPx.toFloat() / maxOf(decoded.width, decoded.height)
        return if (scale >= 1f) decoded
        else Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt().coerceAtLeast(1),
            (decoded.height * scale).toInt().coerceAtLeast(1), true)
    }

    private fun prune(context: Context) {
        val cutoff = System.currentTimeMillis() - KEEP_MS
        dir(context).listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
    }
}
