package dev.mactimit.brb_tracker

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var picker: MethodChannel.Result? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = JobStore(this)
        if (AnalysisService.activeId == null) {
            store.recoverInterrupted()
            // Only scratch downloads owned by stopped jobs; never selected originals.
            java.io.File(noBackupFilesDir, "brb-work").deleteRecursively()
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.mactimit.brb_tracker/local").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "list" -> result.success(store.list().toString())
                    "get" -> result.success(store.get(call.argument<String>("id")!!).toString())
                    "start" -> {
                        val input = JSONObject(call.arguments as Map<*, *>)
                        if (input.optString("video_uri").isEmpty()) Detection.videoId(input.getString("url"))
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 72)
                        result.success(AnalysisService.launch(this, input).toString())
                    }
                    "review" -> result.success(store.review(call.argument<String>("id")!!, call.argument<Int>("index")!!, call.argument<String>("reason")!!).toString())
                    "cancel" -> { AnalysisService.cancel(this, call.argument<String>("id")!!); result.success(null) }
                    "delete" -> { val id = call.argument<String>("id")!!; check(AnalysisService.activeId != id) { "Cancel the running analysis first" }; store.delete(id); result.success(null) }
                    "pick" -> {
                        check(picker == null) { "A file picker is already open" }
                        picker = result
                        val video = call.argument<String>("kind") == "video"
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(if (video) "video/*" else "*/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        if (!video) intent.putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/vtt", "text/plain", "application/octet-stream"))
                        startActivityForResult(intent, 71)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("LOCAL_ANALYSIS", e.message ?: "Local analysis failed", null) }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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
