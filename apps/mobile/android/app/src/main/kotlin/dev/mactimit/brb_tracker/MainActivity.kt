package dev.mactimit.brb_tracker

import android.Manifest
import android.content.Intent
import android.os.Build
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var picker: MethodChannel.Result? = null
    private data class PendingExport(val source: File, val name: String, val result: MethodChannel.Result)
    private var legacyExport: PendingExport? = null
    private val scanSettings by lazy { getSharedPreferences("scan-settings", MODE_PRIVATE) }

    override fun onResume() {
        super.onResume()
        runCatching { AnalysisService.resume(this) }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = JobStore(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.mactimit.brb_tracker/local").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "scan_settings" -> result.success(scanSettings.getString("options", "{}"))
                    "save_scan_settings" -> {
                        val options = JSONObject(call.arguments as Map<*, *>)
                        check(scanSettings.edit().putString("options", options.toString()).commit()) {
                            "Could not save scan settings."
                        }
                        result.success(null)
                    }
                    "resume_queue" -> { AnalysisService.resume(this); result.success(null) }
                    "list" -> result.success(store.list().toString())
                    "get" -> result.success(store.get(call.argument<String>("id")!!).toString())
                    "cached_streams" -> result.success(StreamCatalog.cached(applicationContext))
                    "list_streams" -> {
                        val start = call.argument<Int>("start") ?: 1
                        Thread {
                            try {
                                val page = StreamCatalog.load(applicationContext, start).toString()
                                runOnUiThread { result.success(page) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("STREAM_CATALOG", "Could not load Gamin4Hope’s public streams. Try again.", null) }
                            }
                        }.start()
                    }
                    "diagnose_banner" -> {
                        val uri = android.net.Uri.parse(call.argument<String>("uri")!!)
                        Thread {
                            try {
                                val diagnostic = BannerDiagnostics(this).inspect(uri).toString()
                                runOnUiThread { result.success(diagnostic) }
                            } catch (e: Exception) { runOnUiThread { result.error("BANNER_CHECK", e.message, null) } }
                        }.start()
                    }
                    "start" -> {
                        val input = JSONObject(call.arguments as Map<*, *>)
                        if (input.optString("video_uri").isEmpty()) Detection.videoId(input.getString("url"))
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 72)
                        result.success(AnalysisService.launch(this, input).toString())
                    }
                    "rescan" -> {
                        val id = call.argument<String>("id")!!
                        val settings = JSONObject(call.argument<Map<*, *>>("settings")!!)
                        AnalysisService.rescan(this, id, settings)
                        result.success(null)
                    }
                    "move_up" -> {
                        AnalysisService.moveUp(this, call.argument<String>("id")!!)
                        result.success(null)
                    }
                    "retry_failed" -> result.success(AnalysisService.retryFailed(this, call.argument<String>("id")))
                    "remove_unused_videos" -> result.success(AnalysisService.removeUnusedVideos(this))
                    "remove_video" -> {
                        AnalysisService.removeVideo(this, call.argument<String>("id")!!)
                        result.success(null)
                    }
                    "export_video" -> {
                        val id = call.argument<String>("id")!!
                        val source = store.video(id)
                        check(source.isFile) { "The downloaded VOD is no longer on this phone." }
                        val job = store.get(id)
                        val videoId = runCatching { Detection.videoId(job.getString("url")) }.getOrNull() ?: id
                        exportVideo(source, "brb-$videoId.mp4", result)
                    }
                    "review" -> result.success(store.review(
                        call.argument<String>("id")!!, call.argument<Int>("index")!!,
                        call.argument<String>("reason")!!, call.argument<List<String>>("additional_reasons"),
                    ).toString())
                    "cancel" -> { AnalysisService.cancel(this, call.argument<String>("id")!!); result.success(null) }
                    "delete" -> { store.delete(call.argument<String>("id")!!); result.success(null) }
                    "pick" -> {
                        check(picker == null) { "A file picker is already open" }
                        picker = result
                        val video = call.argument<String>("kind") == "video"
                        val image = call.argument<String>("kind") == "image"
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(if (video) "video/*" else if (image) "image/*" else "*/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        if (!video && !image) intent.putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/vtt", "text/plain", "application/octet-stream"))
                        startActivityForResult(intent, 71)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("LOCAL_ANALYSIS", e.message ?: "Local analysis failed", null) }
        }
    }
    private fun exportVideo(source: File, name: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 29) {
            exportInBackground(result) { VodFiles(applicationContext).exportToDownloads(source, name) }
        } else {
            check(legacyExport == null) { "A video export is already open." }
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("video/mp4").putExtra(Intent.EXTRA_TITLE, name)
                .putExtra(DocumentsContract.EXTRA_INITIAL_URI,
                    Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADownload"))
            startActivityForResult(intent, 73)
            legacyExport = PendingExport(source, name, result)
        }
    }

    private fun exportInBackground(result: MethodChannel.Result, copy: () -> String) {
        Thread {
            try {
                val name = copy()
                runOnUiThread { result.success(name) }
            } catch (e: Exception) {
                runOnUiThread { result.error("VIDEO_EXPORT", e.message ?: "Could not export the VOD.", null) }
            }
        }.start()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 73) {
            val (source, name, result) = legacyExport ?: return
            legacyExport = null
            val destination = data?.data
            if (resultCode == RESULT_OK && destination != null) {
                exportInBackground(result) {
                    val files = VodFiles(applicationContext)
                    try {
                        files.copy(source, destination)
                    } catch (e: Exception) {
                        runCatching { DocumentsContract.deleteDocument(contentResolver, destination) }
                        throw e
                    }
                    files.displayName(destination) ?: name
                }
            } else {
                result.success(null)
            }
            return
        }
        if (requestCode != 71) return
        val pending = picker ?: return
        picker = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) { pending.success(null); return }
        try {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else "Selected file" } ?: "Selected file"
            pending.success(mapOf("uri" to uri.toString(), "name" to name))
        } catch (e: Exception) { pending.error("FILE_ACCESS", e.message, null) }
    }
}
