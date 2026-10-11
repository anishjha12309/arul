package com.hsrutility.arul.upload

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.hsrutility.arul.BuildConfig
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// Converts a picked video so it passes the server's byte QC. Dart plans every number (size, cut,
// bitrates); this side only probes files and runs the export (docs/architecture.md §Uploads).
// API 31+ and ONE export at a time, for the reasons in ShareWatermarkChannel's header.
@UnstableApi
class VideoPrepChannel(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/video_prep"
        const val PROGRESS_CHANNEL = "com.hsrutility.arul/video_prep/progress"
        private const val TAG = "VideoPrep"

        // video_prep_service.dart builds its output paths under this name.
        private const val PREPARED_DIR = "upload_prepared"
        private const val PROGRESS_INTERVAL_MS = 200L

        private fun logd(msg: String) {
            if (BuildConfig.DEBUG) Log.d(TAG, msg)
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val preparedDir = File(context.cacheDir, PREPARED_DIR)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val progressHolder = ProgressHolder()
    private var progressSink: EventChannel.EventSink? = null

    // The busy flag AND the GC anchor: nothing else references the Transformer.
    private var activeExport: ActiveExport? = null

    private class ActiveExport(
        val transformer: Transformer,
        val outputPath: String,
        val result: MethodChannel.Result,
        var replied: Boolean = false,
        var lastProgress: Int = -1,
    )

    init {
        // Engine start, as for MediaPickChannel's picks: nothing Dart holds survives a new isolate,
        // so this is the one moment a sweep cannot delete an output still on its way up.
        scope.launch {
            try {
                preparedDir.deleteRecursively()
            } catch (e: Exception) {
                Log.w(TAG, "prepared-output sweep failed", e)
            }
        }
    }

    private val exportSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> probe(call.argument<String>("path"), result)
            "export" -> export(call, result)
            "cancel" -> {
                cancelExport()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }

    private fun probe(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("bad_input", "path is required", null)
            return
        }
        scope.launch {
            try {
                val facts = readFacts(File(path))
                withContext(Dispatchers.Main) { result.success(facts) }
            } catch (e: CancellationException) {
                throw e // the engine is going away -> nobody is left to answer
            } catch (e: Exception) {
                Log.w(TAG, "probe failed for $path", e)
                withContext(Dispatchers.Main) { result.error("probe_failed", e.message, null) }
            }
        }
    }

    // Width and height are the DISPLAY size; rotation says whether the stored frame is turned.
    private fun readFacts(file: File): Map<String, Any?> {
        require(file.isFile) { "not a file: ${file.path}" }
        val facts = HashMap<String, Any?>()
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            val width = retriever.intOf(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val height = retriever.intOf(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val rotation = retriever.intOf(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val quarterTurn = rotation % 180 != 0
            facts["width"] = if (quarterTurn) height else width
            facts["height"] = if (quarterTurn) width else height
            facts["rotation"] = rotation
            facts["durationMs"] = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            facts["containerMime"] = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
        } finally {
            retriever.release()
        }

        var videoMime: String? = null
        var hasAudio = false
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                    ?: continue
                if (mime.startsWith("video/") && videoMime == null) videoMime = mime
                if (mime.startsWith("audio/")) hasAudio = true
            }
        } finally {
            extractor.release()
        }

        facts["videoMime"] = videoMime
        facts["hasAudio"] = hasAudio
        facts["bytes"] = file.length()
        facts["exportSupported"] = exportSupported
        return facts
    }

    private fun MediaMetadataRetriever.intOf(key: Int): Int =
        extractMetadata(key)?.toIntOrNull() ?: 0

    private fun export(call: MethodCall, result: MethodChannel.Result) {
        if (!exportSupported) {
            // Dart plans around exportSupported, but a Transformer start below 31 would be FATAL.
            result.error(
                "unsupported_api",
                "video conversion needs API 31, this is ${Build.VERSION.SDK_INT}",
                null,
            )
            return
        }
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val endMs = call.argument<Number>("endMs")?.toLong()
        val removeAudio = call.argument<Boolean>("removeAudio") ?: false
        val videoBitrate = call.argument<Int>("videoBitrate") ?: 0
        val audioBitrate = call.argument<Int>("audioBitrate")

        if (inputPath.isNullOrEmpty() || outputPath.isNullOrEmpty() ||
            width <= 0 || height <= 0 || videoBitrate <= 0
        ) {
            result.error(
                "bad_input",
                "inputPath, outputPath, width, height and videoBitrate are required",
                null,
            )
            return
        }
        val input = File(inputPath)
        if (!input.isFile || input.length() == 0L) {
            result.error("bad_input", "input video not readable: $inputPath", null)
            return
        }
        val output = File(outputPath)
        if (!isPreparedOutput(output)) {
            result.error("bad_input", "outputPath must sit under cacheDir/$PREPARED_DIR", null)
            return
        }
        if (activeExport != null) {
            // Nothing queues natively: the caller retries once the current export ends.
            result.error("busy", "another export is running", null)
            return
        }

        try {
            output.parentFile?.mkdirs()
            val transformer = buildTransformer(
                videoBitrate,
                if (removeAudio) null else audioBitrate,
            )
            val export = ActiveExport(transformer, outputPath, result)
            transformer.addListener(exportListener(export))
            // Registered BEFORE start() -> the listener resolves the call through it.
            activeExport = export
            logd("export ${width}x$height endMs=$endMs audio=${!removeAudio} v=$videoBitrate")
            transformer.start(composition(input, width, height, endMs, removeAudio), outputPath)
            mainHandler.postDelayed(progressTick, PROGRESS_INTERVAL_MS)
        } catch (e: Throwable) {
            // Throwable, NOT Exception -> androidx/media#2535 threw NoClassDefFoundError
            // straight out of start().
            Log.e(TAG, "export start failed", e)
            activeExport = null
            mainHandler.removeCallbacks(progressTick)
            output.delete()
            result.error("transform_failed", e.message ?: "could not start export", null)
        }
    }

    private fun isPreparedOutput(file: File): Boolean = try {
        file.canonicalPath.startsWith(preparedDir.canonicalPath + File.separator)
    } catch (e: Exception) {
        false
    }

    private fun composition(
        input: File,
        width: Int,
        height: Int,
        endMs: Long?,
        removeAudio: Boolean,
    ): Composition {
        val mediaItem = MediaItem.Builder().setUri(Uri.fromFile(input))
        if (endMs != null) {
            mediaItem.setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder().setEndPositionMs(endMs).build(),
            )
        }
        val edited = EditedMediaItem.Builder(mediaItem.build())
            .setRemoveAudio(removeAudio)
            .setEffects(
                Effects(
                    /* audioProcessors = */ emptyList(),
                    /* videoEffects = */ listOf(
                        Presentation.createForWidthAndHeight(
                            width,
                            height,
                            Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP,
                        ),
                    ),
                ),
            )
            .build()
        val sequence = if (removeAudio) {
            EditedMediaItemSequence.withVideoFrom(listOf(edited))
        } else {
            EditedMediaItemSequence.withAudioAndVideoFrom(listOf(edited))
        }
        // An HDR phone clip kept as HDR would come out 10-bit, which budget H.264 decoders cannot
        // play -> tone-map to SDR (a no-op for an SDR source).
        return Composition.Builder(sequence)
            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            .build()
    }

    // The default muxer already writes the moov ahead of the mdat when it fits (Mp4Muxer's
    // attemptStreamableOutputEnabled, on by default), so nothing here asks for faststart.
    private fun buildTransformer(videoBitrate: Int, audioBitrate: Int?): Transformer {
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder().setBitrate(videoBitrate).build(),
            )
            .setEnableFallback(true)
        if (audioBitrate != null && audioBitrate > 0) {
            encoders.setRequestedAudioEncoderSettings(
                AudioEncoderSettings.Builder().setBitrate(audioBitrate).build(),
            )
        }
        // The paused feed can hold every hardware decoder on a budget SoC -> fall back to software.
        val decoders = DefaultDecoderFactory.Builder(context)
            .setEnableDecoderFallback(true)
            .build()
        return Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            // The default turns a portrait frame to landscape plus a rotation hint, and the server
            // checks the STORED width against the 128 rule: 1824 wide would fail it.
            .setPortraitEncodingEnabled(true)
            .setEncoderFactory(encoders.build())
            .setAssetLoaderFactory(
                DefaultAssetLoaderFactory(context, decoders, Clock.DEFAULT, null),
            )
            .build()
    }

    private fun exportListener(export: ActiveExport): Transformer.Listener =
        object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                logd(
                    "export done ${exportResult.width}x${exportResult.height} " +
                        "v=${exportResult.averageVideoBitrate} ${exportResult.videoEncoderName} " +
                        "${exportResult.fileSizeBytes}B",
                )
                finish(export) {
                    it.result.success(
                        mapOf("path" to it.outputPath, "bytes" to File(it.outputPath).length()),
                    )
                }
            }

            override fun onError(
                composition: Composition,
                exportResult: ExportResult,
                exportException: ExportException,
            ) {
                Log.e(TAG, "export failed: ${exportException.errorCodeName}", exportException)
                finish(export) {
                    // A torn half-written MP4 must never reach an upload.
                    File(it.outputPath).delete()
                    it.result.error(
                        "transform_failed",
                        "${exportException.errorCodeName}: ${exportException.message}",
                        null,
                    )
                }
            }
        }

    // The identity check drops a callback from an export that was already cancelled or replaced.
    private inline fun finish(export: ActiveExport, reply: (ActiveExport) -> Unit) {
        if (activeExport !== export) return
        activeExport = null
        mainHandler.removeCallbacks(progressTick)
        if (export.replied) return
        export.replied = true
        try {
            reply(export)
        } catch (e: Throwable) {
            // A dead engine's Result can throw -> the export itself has already ended.
            Log.w(TAG, "could not deliver export result", e)
        }
    }

    // Transformer has no progress callback, only getProgress on its own looper (main here).
    private val progressTick: Runnable = object : Runnable {
        override fun run() {
            val export = activeExport ?: return
            try {
                val state = export.transformer.getProgress(progressHolder)
                val percent = progressHolder.progress
                val available = state == Transformer.PROGRESS_STATE_AVAILABLE
                if (available && percent != export.lastProgress) {
                    export.lastProgress = percent
                    progressSink?.success(percent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "progress poll failed", e)
            }
            mainHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
        }
    }

    // Transformer.cancel() fires no listener and leaves the partial file -> both are done here.
    private fun cancelExport() {
        val export = activeExport ?: return
        activeExport = null
        mainHandler.removeCallbacks(progressTick)
        try {
            export.transformer.cancel()
        } catch (e: Throwable) {
            Log.w(TAG, "cancel failed", e)
        }
        File(export.outputPath).delete()
        if (export.replied) return
        export.replied = true
        try {
            export.result.error("cancelled", "export cancelled", null)
        } catch (e: Throwable) {
            Log.w(TAG, "could not deliver cancel", e)
        }
    }

    fun dispose() {
        mainHandler.removeCallbacks(progressTick)
        val export = activeExport
        activeExport = null
        if (export != null) {
            try {
                export.transformer.cancel()
            } catch (e: Throwable) {
                Log.w(TAG, "cancel on dispose failed", e)
            }
            File(export.outputPath).delete()
            // No result.error here -> the engine is going away and the Result with it.
        }
        progressSink = null
        scope.cancel()
    }
}
