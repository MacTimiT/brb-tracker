package dev.mactimit.brb_tracker

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.security.MessageDigest
import java.util.zip.ZipInputStream

/** Installs the pinned English model once in app-private storage. No audio is uploaded. */
class SpeechModelStore(private val context: Context) {
    companion object {
        private const val NAME = "vosk-model-small-en-us-0.15"
        private const val URL = "https://alphacephei.com/vosk/models/$NAME.zip"
        private const val SHA256 = "30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498"
        private const val MAX_ARCHIVE = 50L * 1024 * 1024
        private const val MAX_EXTRACTED = 160L * 1024 * 1024
        private const val EXPECTED_ARCHIVE = 41_205_931L
        private const val EXPECTED_EXTRACTED = 70_898_967L
    }

    fun get(cancelled: () -> Boolean, progress: (Double) -> Unit): File {
        val root = File(context.noBackupFilesDir, "speech-models").apply { mkdirs() }
        val installed = File(root, NAME)
        if (File(installed, ".brb-complete").isFile && File(installed, "am/final.mdl").isFile) {
            progress(0.99)
            return installed
        }
        check(root.usableSpace > 250L * 1024 * 1024) { "Free at least 250 MB to install the English speech model" }
        val archive = File(root, "$NAME.download")
        val staging = File(root, "$NAME.staging")
        archive.delete()
        staging.deleteRecursively()
        try {
            val connection = (java.net.URL(URL).openConnection() as HttpURLConnection).apply {
                connectTimeout = 20_000
                readTimeout = 30_000
                instanceFollowRedirects = true
            }
            try {
                check(connection.responseCode == 200) { "English speech model download failed (HTTP ${connection.responseCode})" }
                check(connection.contentLengthLong < 0 || connection.contentLengthLong in 1..MAX_ARCHIVE) { "Unexpected English speech model size" }
                val digest = MessageDigest.getInstance("SHA-256")
                connection.inputStream.use { input -> archive.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var size = 0L
                    while (true) {
                        if (cancelled()) throw java.util.concurrent.CancellationException()
                        val count = input.read(buffer)
                        if (count < 0) break
                        size += count
                        check(size <= MAX_ARCHIVE) { "English speech model archive is too large" }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                        progress(0.6 * size / EXPECTED_ARCHIVE)
                    }
                } }
                check(archive.length() == EXPECTED_ARCHIVE) { "English speech model archive has an unexpected size" }
                check(digest.digest().joinToString("") { "%02x".format(it) } == SHA256) { "English speech model checksum did not match" }
            } finally { connection.disconnect() }
            staging.mkdirs()
            var extracted = 0L
            ZipInputStream(archive.inputStream().buffered()).use { zip ->
                while (true) {
                    if (cancelled()) throw java.util.concurrent.CancellationException()
                    val entry = zip.nextEntry ?: break
                    val relative = entry.name.removePrefix("$NAME/")
                    if (entry.name == "$NAME/") { zip.closeEntry(); continue }
                    require(entry.name.startsWith("$NAME/") && relative.isNotEmpty() && !relative.split('/').contains("..")) { "Unsafe English speech model archive" }
                    val target = File(staging, relative)
                    require(target.canonicalPath.startsWith(staging.canonicalPath + File.separator)) { "Unsafe English speech model path" }
                    if (entry.isDirectory) target.mkdirs() else {
                        target.parentFile?.mkdirs()
                        target.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                if (cancelled()) throw java.util.concurrent.CancellationException()
                                val count = zip.read(buffer)
                                if (count < 0) break
                                extracted += count
                                check(extracted <= MAX_EXTRACTED) { "English speech model expanded too far" }
                                output.write(buffer, 0, count)
                                progress(0.6 + 0.39 * (extracted.toDouble() / EXPECTED_EXTRACTED).coerceAtMost(1.0))
                            }
                        }
                    }
                    zip.closeEntry()
                }
            }
            check(File(staging, "am/final.mdl").isFile) { "English speech model is incomplete" }
            File(staging, ".brb-complete").writeText(SHA256)
            installed.deleteRecursively()
            check(staging.renameTo(installed)) { "Could not install English speech model" }
            progress(0.99)
            return installed
        } finally {
            archive.delete()
            staging.deleteRecursively()
        }
    }
}
