package dev.mactimit.brb_tracker

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File

/** Finished downloads live outside the analysis scratch directory. */
class VodFiles(private val context: Context) {
    private fun directory(id: String): File {
        require(Regex("[a-zA-Z0-9-]+").matches(id))
        return File(context.noBackupFilesDir, "brb-vods/$id")
    }

    fun video(id: String) = File(directory(id), "vod.mp4")
    fun captions(id: String) = File(directory(id), "captions.json3")
    fun audio(id: String) = File(directory(id), "audio")
    fun delete(id: String) {
        check(directory(id).deleteRecursively()) { "Could not remove the downloaded VOD." }
    }

    fun retain(source: File, destination: File) {
        destination.parentFile?.mkdirs()
        check(source.renameTo(destination)) { "Could not keep the downloaded VOD file." }
    }

    @androidx.annotation.RequiresApi(29)
    fun exportToDownloads(source: File, name: String): String {
        val resolver = context.contentResolver
        val destination = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }) ?: error("Could not create a file in Downloads.")
        try {
            copy(source, destination)
            check(resolver.update(destination, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null) == 1) { "Could not finish the export." }
            return displayName(destination) ?: name
        } catch (e: Exception) {
            resolver.delete(destination, null, null)
            throw e
        }
    }

    fun displayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
    }.getOrNull()

    fun copy(source: File, destination: Uri) {
        source.inputStream().use { input ->
            val output = context.contentResolver.openOutputStream(destination, "wt")
                ?: error("Could not write the exported VOD.")
            output.use { input.copyTo(it) }
        }
    }
}
