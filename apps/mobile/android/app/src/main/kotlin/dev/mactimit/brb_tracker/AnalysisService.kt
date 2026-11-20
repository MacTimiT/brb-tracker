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
        private val queueLock = Any()
        private var scheduled = false

        fun launch(context: Context, input: JSONObject): JSONObject = synchronized(queueLock) {
            val store = JobStore(context)
            val job = store.create(input)
            try {
                startPending(context, store)
            } catch (e: Exception) {
                store.update(job.getString("id")) {
                    it.put("status", "failed").put("stage", "Failed")
                        .put("error", "Android did not allow the analysis to start")
                }
                throw e
            }
            job
        }

        fun rescan(context: Context, id: String, settings: JSONObject): JSONObject =
            synchronized(queueLock) {
                launch(context, JobStore(context).rescanInput(id, settings))
            }

        fun removeVideo(context: Context, id: String) = synchronized(queueLock) {
            JobStore(context).removeVideo(id)
        }

        fun resume(context: Context) = synchronized(queueLock) {
            if (!scheduled) {
                val store = JobStore(context)
                store.recoverInterrupted()
                File(context.noBackupFilesDir, "brb-work").deleteRecursively()
                startPending(context, store)
            }
        }

        private fun startPending(context: Context, store: JobStore) {
            if (scheduled || store.queuedId() == null) return
            scheduled = true
            try {
                context.startForegroundService(Intent(context, AnalysisService::class.java))
            } catch (e: Exception) {
                scheduled = false
                throw e
            }
        }

        fun cancel(context: Context, id: String) = synchronized(queueLock) {
            if (activeId == id) {
                context.startService(Intent(context, AnalysisService::class.java).setAction("cancel").putExtra("id", id))
            } else {
                require(JobStore(context).cancelQueued(id)) { "That scan is no longer in the queue." }
            }
        }
    }
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var cancelled = false
    @Volatile private var timedOut = false
    @Volatile private var destroyed = false
    private var draining = false
    private var wakeLock: PowerManager.WakeLock? = null
    private lateinit var store: JobStore
    private var jobProgress = JobProgress()
    @Volatile private var speechExpected = false

    override fun onCreate() {
        super.onCreate()
        store = JobStore(this)
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL, "VOD analysis", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "cancel") {
            val id = intent.getStringExtra("id")
            synchronized(queueLock) {
                if (id != null && id == activeId && store.get(id).optString("status") == "running") {
                    cancelled = true
                    YoutubeDL.destroyProcessById(id)
                    store.update(id) { job -> job.put("stage", "Cancelling").put("phase_progress", JSONObject.NULL) }
                } else if (!draining) {
                    stopSelf()
                }
            }
            return START_NOT_STICKY
        }
        if (!draining) {
            // Start the foreground service before any downloader setup or OCR.
            beginForeground("Preparing queue", null, false)
            draining = true
            worker.execute(::drain)
        }
        return START_NOT_STICKY
    }

    private fun drain() {
        try {
            while (true) {
                val id = synchronized(queueLock) {
                    if (destroyed || timedOut) null
                    else store.queuedId()?.also { next ->
                        cancelled = false
                        speechExpected = false
                        jobProgress = JobProgress()
                        store.update(next) { it.put("status", "running").put("stage", "Preparing") }
                        activeId = next
                    }
                } ?: break
                try {
                    wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "brb-tracker:analysis")
                        .apply { acquire(6 * 60 * 60 * 1000L) }
                    runJob(id)
                } finally {
                    synchronized(queueLock) {
                        activeId = null
                        if (wakeLock?.isHeld == true) wakeLock?.release()
                        wakeLock = null
                    }
                }
            }
        } finally {
            android.os.Handler(mainLooper).post {
                synchronized(queueLock) {
                    if (!destroyed && !timedOut && store.queuedId() != null) {
                        worker.execute(::drain)
                    } else {
                        scheduled = false
                        draining = false
                        if (!destroyed) {
                            stopForeground(STOP_FOREGROUND_REMOVE)
                            stopSelf()
                        }
                    }
                }
            }
        }
    }
    private fun serviceType(processing: Boolean): Int = when {
        Build.VERSION.SDK_INT < 29 -> 0
        Build.VERSION.SDK_INT >= 35 && processing -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
        else -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    }
    private fun beginForeground(stage: String, percent: Int?, processing: Boolean) {
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification(stage, percent), serviceType(processing))
        else startForeground(NOTIFICATION, notification(stage, percent))
    }
    private fun notification(stage: String, percent: Int?): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val id = activeId
        val cancel = id?.let {
            val intent = Intent(this, AnalysisService::class.java).setAction("cancel")
                .setData(Uri.fromParts("brb-scan", id, null)).putExtra("id", id)
            PendingIntent.getService(this, 1, intent, PendingIntent.FLAG_IMMUTABLE)
        }
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_brb_notification).setContentTitle("BRB Tracker")
            .setContentText(stage).setContentIntent(open).setOngoing(true).setProgress(100, percent ?: 0, percent == null)
            .apply { if (cancel != null) addAction(Notification.Action.Builder(null, "Cancel", cancel).build()) }
            .build()
    }
    @Synchronized private fun progress(id: String, phase: JobPhase, value: Double? = null) {
        if (cancelled || activeId != id) return
        if (!jobProgress.update(phase, value)) return
        val fraction = jobProgress.fraction
        val overall = when (phase) {
            JobPhase.DOWNLOAD -> (fraction ?: 0.0) * 0.3
            JobPhase.ANALYSIS -> 0.3 + (fraction ?: 0.0) * (if (speechExpected) 0.5 else 0.7)
            JobPhase.AUDIO -> 0.8 + (fraction ?: 0.0) * 0.1
            JobPhase.MODEL -> 0.9 + (fraction ?: 0.0) * 0.05
            JobPhase.SPEECH -> 0.95 + (fraction ?: 0.0) * 0.05
            else -> 0.0
        }
        store.update(id) {
            it.put("status", "running").put("stage", phase.label).put("progress", overall)
                .put("phase", phase.name.lowercase()).put("phase_progress", fraction ?: JSONObject.NULL)
        }
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(phase.label, fraction?.times(100)?.toInt()))
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
            var cues = if (!input.has("probe_seconds") && input.optString("transcript_uri").isNotBlank()) readTranscript(Uri.parse(input.getString("transcript_uri"))) else emptyList()
            input.put("transcript_source", if (cues.isEmpty()) "none" else "imported")
            var captionWarning: String? = null
            val files = VodFiles(this)
            val reuse = input.optString("reuse_media").takeIf { it.isNotEmpty() }
            val localUri = input.optString("video_uri")
            val video: Uri
            if (reuse != null) {
                val retained = files.video(reuse)
                check(retained.isFile) { "The saved video is no longer available." }
                val captions = files.captions(reuse)
                if (cues.isEmpty() && captions.isFile) {
                    cues = Detection.parseTranscript(captions.readText())
                    if (cues.isNotEmpty()) input.put("transcript_source", "youtube-captions")
                }
                video = Uri.fromFile(retained)
            } else if (localUri.isNotBlank()) {
                video = Uri.parse(localUri)
            } else {
                val videoId = Detection.videoId(input.getString("url"))
                val url = "https://www.youtube.com/watch?v=$videoId"
                input.put("url", url)
                check(work.usableSpace > 1024L * 1024 * 1024) { "Free at least 1 GB of phone storage before downloading a VOD" }
                beginForeground("Preparing download", null, false)
                progress(id, JobPhase.PREPARING)
                YoutubeDL.init(this)
                FFmpeg.init(this)
                // Keep the extractor usable as YouTube changes. An update
                // failure falls back to the bundled version, never a server.
                runCatching { YoutubeDL.updateYoutubeDL(this, YoutubeDL.UpdateChannel.STABLE) }
                checkCancelled()
                progress(id, JobPhase.METADATA)
                val metadataRequest = request(url).apply { addOption("--dump-single-json"); addOption("--skip-download") }
                val metadata = JSONObject(YoutubeDL.execute(metadataRequest, id, null).out)
                check(!metadata.optBoolean("is_live", false)) { "Wait until the livestream has ended before analyzing its VOD" }
                input.put("title", metadata.optString("title", videoId))
                val dates = VodMetadata.date(metadata)
                for (field in listOf("vod_date", "vod_date_source", "stream_started_at")) input.put(field, dates.get(field))
                store.update(id) { it.put("title", input.getString("title")).put("vod_date", dates.get("vod_date")) }
                if (cues.isEmpty() && !input.has("probe_seconds")) {
                    progress(id, JobPhase.CAPTIONS)
                    try {
                        val captions = request(url).apply {
                            addOption("--skip-download"); addOption("--write-subs"); addOption("--write-auto-subs")
                            addOption("--sub-langs", "en.*"); addOption("--sub-format", "json3")
                            addOption("-o", File(work, "vod.%(ext)s").absolutePath)
                        }
                        YoutubeDL.execute(captions, id, null)
                        work.listFiles().orEmpty().firstOrNull { it.extension == "json3" }?.let {
                            cues = Detection.parseTranscript(it.readText())
                            if (cues.isNotEmpty()) input.put("transcript_source", "youtube-captions")
                        }
                    } catch (e: Exception) { checkCancelled(); captionWarning = "YouTube captions could not be downloaded. Import a transcript or review reasons manually." }
                }
                checkCancelled()
                progress(id, JobPhase.DOWNLOAD, 0.0)
                val media = request(url).apply {
                    addOption("-f", VodMetadata.format(input.optInt("download_height", 480)))
                    addOption("--max-filesize", "4G")
                    addOption("--concurrent-fragments", 4)
                    addOption("--match-filter", "!is_live")
                    addOption("-o", File(work, "vod.%(ext)s").absolutePath)
                    addOption("--newline")
                    // Use downloader progress callbacks for the download phase.
                }
                YoutubeDL.execute(media, id) { percent, _, _ ->
                    if (cancelled) YoutubeDL.destroyProcessById(id)
                    progress(id, JobPhase.DOWNLOAD, percent / 100.0)
                }
                val downloaded = work.listFiles().orEmpty().firstOrNull { it.extension == "mp4" } ?: error("YouTube did not provide a downloadable MP4. Try importing a local video.")
                if (input.has("probe_seconds")) {
                    video = Uri.fromFile(downloaded)
                } else {
                    store.update(id) { it.put("input", input) }
                    if (input.optString("transcript_source") == "youtube-captions") {
                        work.listFiles().orEmpty().firstOrNull { it.extension == "json3" }
                            ?.let { files.retain(it, files.captions(id)) }
                    }
                    val retained = files.video(id)
                    files.retain(downloaded, retained)
                    video = Uri.fromFile(retained)
                }
            }
            checkCancelled()
            if (input.has("probe_seconds")) {
                progress(id, JobPhase.ANALYSIS, 0.0)
                beginForeground("Checking requested VOD frame", null, true)
                val diagnostic = BannerDiagnostics(this).inspectVideo(video, input.getDouble("probe_seconds"))
                checkCancelled()
                store.update(id) { it.put("status", "completed").put("stage", "VOD frame ready")
                    .put("progress", 1.0).put("phase_progress", 1.0).put("phase", "completed").put("diagnostic", diagnostic) }
                return
            }
            speechExpected = cues.isEmpty() && input.optBoolean("speech_fallback", true)
            progress(id, JobPhase.ANALYSIS, 0.0)
            beginForeground(JobPhase.ANALYSIS.label, 0, true)
            val report = LocalAnalyzer(this).analyze(video, input, id, cues, { cancelled }) {
                progress(id, JobPhase.ANALYSIS, it)
            }
            checkCancelled()
            val breaks = report.getJSONArray("breaks")
            if (cues.isEmpty() && breaks.length() > 0 && input.optBoolean("speech_fallback", true)) {
                beginForeground("Preparing speech fallback", null, true)
                try {
                    var audio = video
                    if (reuse != null && files.audio(reuse).isFile) {
                        audio = Uri.fromFile(files.audio(reuse))
                    } else if (reuse == null && localUri.isBlank()) {
                        check(work.usableSpace > 512L * 1024 * 1024) { "Free at least 512 MB for the VOD audio" }
                        progress(id, JobPhase.AUDIO)
                        val audioRequest = request(input.getString("url")).apply {
                            addOption("-f", "bestaudio[abr<=64][ext=m4a]/bestaudio[abr<=64]/bestaudio[ext=m4a]/bestaudio")
                            addOption("--max-filesize", "512M")
                            addOption("--concurrent-fragments", 4)
                            addOption("-o", File(work, "speech.%(ext)s").absolutePath)
                        }
                        YoutubeDL.execute(audioRequest, id) { percent, _, _ ->
                            if (cancelled) YoutubeDL.destroyProcessById(id)
                            progress(id, JobPhase.AUDIO, percent / 100.0)
                        }
                        val downloadedAudio = work.listFiles().orEmpty().firstOrNull { it.name.startsWith("speech.") && it.isFile }
                            ?: error("The VOD audio was not downloaded")
                        val retainedAudio = files.audio(id)
                        files.retain(downloadedAudio, retainedAudio)
                        audio = Uri.fromFile(retainedAudio)
                    }
                    val starts = (0 until breaks.length()).map { breaks.getJSONObject(it).getDouble("start_seconds") }
                    progress(id, JobPhase.MODEL, 0.0)
                    val spoken = SpeechTranscriber(this).transcribe(audio, starts, { cancelled },
                        { progress(id, JobPhase.MODEL, it) }, { progress(id, JobPhase.SPEECH, it) })
                    checkCancelled()
                    if (spoken.isNotEmpty()) {
                        for (index in 0 until breaks.length()) {
                            val item = breaks.getJSONObject(index)
                            val (reason, evidence) = Detection.reason(spoken, item.getDouble("start_seconds"))
                            item.put("reason", reason).put("suggested_reason", reason).put("evidence", evidence)
                                .put("confidence", if (reason == "Unknown") "unknown" else "keyword")
                        }
                        report.put("transcript_source", "on-device-speech")
                        val warnings = report.getJSONArray("warnings")
                        report.put("warnings", org.json.JSONArray((0 until warnings.length()).map { warnings.getString(it) }
                            .filterNot { it.startsWith("No usable transcript.") }))
                        report.getJSONArray("warnings").put("On-device speech recognition can mishear words. Review reason evidence before publishing.")
                    }
                } catch (e: Exception) {
                    checkCancelled()
                    report.getJSONArray("warnings").put("On-device speech transcription failed: ${e.message ?: "audio or model unavailable"}. Review Unknown reasons manually.")
                }
            }
            if (report.getString("transcript_source") == "none") captionWarning?.let { report.getJSONArray("warnings").put(it) }
            store.update(id) { it.put("status", "completed").put("stage", "Saved on this phone").put("phase", "completed").put("phase_progress", 1.0).put("progress", 1.0).put("title", report.getString("title")).put("report", report) }
        } catch (e: Exception) {
            val wasCancelled = cancelled || e is CancellationException || e is YoutubeDL.CanceledException
            store.update(id) {
                it.put("status", if (wasCancelled && !timedOut) "cancelled" else "failed").put("stage", if (wasCancelled && !timedOut) "Cancelled" else "Failed")
                    .put("phase", if (wasCancelled && !timedOut) "cancelled" else "failed").put("phase_progress", JSONObject.NULL)
                    .put("error", if (timedOut) "Android's background processing time limit was reached. Keep the app open or analyze a shorter VOD." else if (wasCancelled) "Analysis cancelled. No results were published." else (e.message ?: "Local analysis failed").takeLast(1200))
            }
        } finally {
            work.deleteRecursively()
        }
    }
    private fun checkCancelled() { if (cancelled) throw CancellationException("Analysis cancelled") }
    override fun onTimeout(startId: Int, fgsType: Int) {
        synchronized(queueLock) {
            timedOut = true
            cancelled = true
            activeId?.let { YoutubeDL.destroyProcessById(it) }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        synchronized(queueLock) {
            destroyed = true
            cancelled = true
            if (draining) activeId?.let { YoutubeDL.destroyProcessById(it) }
        }
        worker.shutdown()
        super.onDestroy()
    }
}
