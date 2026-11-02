package com.sixbit.pubsubpush

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Serves cached images to the system UI, which can't read our files: a chat
 * notification's picture has to be a content URI. Not exported; the
 * notification system grants read access to the URIs a notification names.
 */
class ImageProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val name = uri.lastPathSegment?.takeIf { NAME.matches(it) } ?: throw FileNotFoundException(uri.toString())
        val file = File(Images.dir(context!!), name)
        if (!file.isFile) throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri) = "image/*"
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0

    companion object {
        private const val AUTHORITY = "com.sixbit.pubsubpush.images"
        private val NAME = Regex("[0-9a-f]{64}")

        fun uri(file: File): Uri = Uri.parse("content://$AUTHORITY/${file.name}")
    }
}
