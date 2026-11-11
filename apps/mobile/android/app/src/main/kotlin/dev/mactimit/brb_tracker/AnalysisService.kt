package dev.mactimit.brb_tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.ffmpeg.FFmpeg
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors

class AnalysisService : Service() {
    companion object {
        @Volatile var activeId: String? = null
            private set
        private const val NOTIFICATION = 19
        private const val CHANNEL = "brb-analysis"
        @Synchronized fun launch(context: Context, input: JSONObject): JSONObject {
            check(activeId == null) { "An analysis is already running. Finish or cancel it first." }
            val store = JobStore(context)
            val job = store.create(input)
            val id = job.getString("id")
            activeId = id
            try { context.startForegroundService(Intent(context, AnalysisService::class.java).putExtra("id", id)) }
            catch (e: Exception) { activeId = null; store.update(id) { it.put("status", "failed").put("error", "Android did not allow the analysis to start") }; throw e }
            return job
        }
        fun cancel(context: Context, id: String) {
            require(activeId == id) { "That analysis is not running" }
            context.startService(Intent(context, AnalysisService::class.java).setAction("cancel"))
        }
    }
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var cancelled = false
    @Volatile private var timedOut = false
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var store: JobStore
    private var lastPercent = -1
    private var currentStage = "Preparing"

    override fun onCreate() {
        super.onCreate()
        store = JobStore(this)
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL, "VOD analysis", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "cancel") {
            cancelled = true
            activeId?.let { YoutubeDL.destroyProcessById(it) }
            return START_NOT_STICKY
        }
        val id = intent?.getStringExtra("id") ?: run { stopSelf(); return START_NOT_STICKY }
        // startForeground must happen immediately, before model extraction or downloads.
        beginForeground("Preparing local analysis", 0, false)
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "brb-tracker:analysis").apply { acquire(6 * 60 * 60 * 1000L) }
        worker.execute { runJob(id) }
        return START_NOT_STICKY
    }
    private fun serviceType(processing: Boolean): Int = if (Build.VERSION.SDK_INT >= 35 && processing) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    private fun beginForeground(stage: String, percent: Int, processing: Boolean) {
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification(stage, percent), serviceType(processing))
        else startForeground(NOTIFICATION, notification(stage, percent))
    }
    private fun notification(stage: String, percent: Int): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val cancel = PendingIntent.getService(this, 1, Intent(this, AnalysisService::class.java).setAction("cancel"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, CHANNEL).setSmallIcon(applicationInfo.icon).setContentTitle("BRB Tracker · analyzing on this phone")
            .setContentText(stage).setContentIntent(open).setOngoing(true).setProgress(100, percent, percent == 0)
            .addAction(Notification.Action.Builder(null, "Cancel", cancel).build()).build()
    }
    private fun progress(id: String, stage: String, value: Double) {
        val percent = (value.coerceIn(0.0, 1.0) * 100).toInt()
        if (percent == lastPercent && stage == currentStage) return
        lastPercent = percent
        currentStage = stage
        store.update(id) { it.put("status", "running").put("stage", stage).put("progress", value) }
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(stage, percent))
    }
    private fun readTranscript(uri: Uri): List<Cue> {
        val text = contentResolver.openInputStream(uri)?.use { stream ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                require(output.size() + count <= 10 * 1024 * 1024) { "Transcript must be smaller than 10 MB" }
                output.write(buffer, 0, count)
            }
            output.toString("UTF-8")
        } ?: error("Could not read the selected transcript")
        return Detection.parseTranscript(text)
    }
    private fun request(url: String) = YoutubeDLRequest(url).apply {
        addOption("--no-playlist"); addOption("--socket-timeout", 30); addOption("--retries", 2)
        addOption("--no-mtime")
    }
    private fun runJob(id: String) {
        val work = File(noBackupFilesDir, "brb-work/$id").apply { mkdirs() }
        try {
            val input = store.get(id).getJSONObject("input")
            var cues = if (input.optString("transcript_uri").isNotBlank()) readTranscript(Uri.parse(input.getString("transcript_uri"))) else emptyList()
            var captionWarning: String? = null
            val localUri = input.optString("video_uri")
            val video: Uri
            if (localUri.isNotBlank()) {
                video = Uri.parse(localUri)
            } else {
                val videoId = Detection.videoId(input.getString("url"))
                val url = "https://www.youtube.com/watch?v=$videoId"
                input.put("url", url)
                check(work.usableSpace > 1024L * 1024 * 1024) { "Free at least 1 GB of phone storage before downloading a VOD" }
                progress(id, "Preparing on-device downloader", 0.0)
                YoutubeDL.init(this)
                FFmpeg.init(this)
                // Keep the extractor usable as YouTube changes. An update
                // failure falls back to the bundled version, never a server.
                runCatching { YoutubeDL.updateYoutubeDL(this, YoutubeDL.UpdateChannel.STABLE) }
                checkCancelled()
                progress(id, "Reading YouTube VOD details", 0.0)
                val metadataRequest = request(url).apply { addOption("--dump-single-json"); addOption("--skip-download") }
                val metadata = JSONObject(YoutubeDL.execute(metadataRequest, id, null).out)
                check(!metadata.optBoolean("is_live", false)) { "Wait until the livestream has ended before analyzing its VOD" }
                input.put("title", metadata.optString("title", videoId))
                if (cues.isEmpty()) {
                    progress(id, "Downloading available English captions", 0.0)
                    try {
                        val captions = request(url).apply {
                            addOption("--skip-download"); addOption("--write-subs"); addOption("--write-auto-subs")
                            addOption("--sub-langs", "en,en-orig"); addOption("--sub-format", "json3")
                            addOption("-o", File(work, "vod.%(ext)s").absolutePath)
                        }
                        YoutubeDL.execute(captions, id, null)
                        work.listFiles().orEmpty().firstOrNull { it.extension == "json3" }?.let { cues = Detection.parseTranscript(it.readText()) }
                    } catch (e: Exception) { checkCancelled(); captionWarning = "YouTube captions could not be downloaded. Import a transcript or review reasons manually." }
                }
                checkCancelled()
                progress(id, "Downloading video to this phone", 0.0)
                val media = request(url).apply {
                    addOption("-f", "best[height<=480][ext=mp4][vcodec^=avc1]/bestvideo[height<=480][ext=mp4][vcodec^=avc1]/best[height<=480][ext=mp4]")
                    addOption("--max-filesize", "4G")
                    addOption("--match-filter", "!is_live")
                    addOption("-o", File(work, "vod.%(ext)s").absolutePath)
                    addOption("--newline")
                    // Use downloader progress callbacks for the download phase.
                }
                YoutubeDL.execute(media, id) { percent, _, _ ->
                    if (cancelled) YoutubeDL.destroyProcessById(id)
                    progress(id, "Downloading video to this phone", (percent / 100.0 * 0.3).coerceIn(0.0, 0.3))
                }
                val downloaded = work.listFiles().orEmpty().firstOrNull { it.extension == "mp4" } ?: error("YouTube did not provide a downloadable MP4. Try importing a local video.")
                video = Uri.fromFile(downloaded)
            }
            checkCancelled()
            beginForeground("Scanning BRB screens locally", 30, true)
            val report = LocalAnalyzer(this).analyze(video, input, id, cues, { cancelled }) {
                progress(id, "Scanning BRB screens locally", 0.3 + it * 0.7)
            }
            checkCancelled()
            captionWarning?.let { report.getJSONArray("warnings").put(it) }
            store.update(id) { it.put("status", "completed").put("stage", "Saved on this phone").put("progress", 1.0).put("title", report.getString("title")).put("report", report) }
        } catch (e: Exception) {
            val wasCancelled = cancelled || e is CancellationException || e is YoutubeDL.CanceledException
            store.update(id) {
                it.put("status", if (wasCancelled && !timedOut) "cancelled" else "failed").put("stage", if (wasCancelled && !timedOut) "Cancelled" else "Failed")
                    .put("error", if (timedOut) "Android's background processing time limit was reached. Keep the app open or analyze a shorter VOD." else if (wasCancelled) "Analysis cancelled. No results were published." else (e.message ?: "Local analysis failed").takeLast(1200))
            }
        } finally {
            work.deleteRecursively()
            activeId = null
            if (wakeLock?.isHeld == true) wakeLock?.release()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }
    private fun checkCancelled() { if (cancelled) throw CancellationException("Analysis cancelled") }
    override fun onTimeout(startId: Int, fgsType: Int) {
        timedOut = true
        cancelled = true
        activeId?.let { id ->
            YoutubeDL.destroyProcessById(id)
            store.update(id) { it.put("status", "failed").put("error", "Android's background processing time limit was reached. Keep the app open or analyze a shorter VOD.") }
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onDestroy() { cancelled = true; activeId?.let { YoutubeDL.destroyProcessById(it) }; if (wakeLock?.isHeld == true) wakeLock?.release(); worker.shutdown(); super.onDestroy() }
}
