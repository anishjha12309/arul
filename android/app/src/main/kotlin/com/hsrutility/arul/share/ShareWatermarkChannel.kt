package com.hsrutility.arul.share

import android.content.Context
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Burns the watermark into a live wallpaper's MP4 at SHARE time via Media3 Transformer -> no ffmpeg on device.
// REQUIRES API 31 -> Media3's ExoPlayerAssetLoader.Factory references android.media.metrics.LogSessionId unguarded.
// Only ONE export runs at a time -> Transformer holds a hardware decoder AND an encoder for the duration.
// On budget SoCs that budget is shared with the feed's preview pool -> a concurrent export is decoder starvation.
// MethodChannel handlers arrive on the platform main thread, which has a Looper -> exactly what Transformer requires.
@UnstableApi
class ShareWatermarkChannel(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/share_watermark"
        private const val TAG = "ShareWatermark"

        // Once per process: whether the clip's audio was copied through (TRANSMUXED) or re-encoded.
        private var loggedAudioProcess = false
    }

    // The in-flight export doubles as the busy flag AND the GC anchor.
    // Nothing else references the Transformer -> one collected mid-flight just silently dies.
    private var activeExport: ActiveExport? = null

    private class ActiveExport(
        val transformer: Transformer,
        val outputPath: String,
        val result: MethodChannel.Result,
        /** Transformer never double-fires, but the guard costs nothing. */
        var replied: Boolean = false,
    )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "videoWatermarkSupport" -> result.success(
                mapOf(
                    "supported" to videoWatermarkSupported,
                    "sdkInt" to Build.VERSION.SDK_INT,
                ),
            )
            "watermarkVideo" -> watermarkVideo(call, result)
            else -> result.notImplemented()
        }
    }

    // Whether an export can run at all on this device -> API 31, not a codec probe; see the class doc.
    // Dart asks FIRST -> it then skips rendering a full-frame overlay PNG it would only throw away.
    private val videoWatermarkSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    private fun watermarkVideo(call: MethodCall, result: MethodChannel.Result) {
        if (!videoWatermarkSupported) {
            // Defence in depth -> Dart gates on videoWatermarkSupport, but calling Transformer here would be FATAL.
            // So this never relies on the caller having asked.
            result.error(
                "unsupported_api",
                "video watermarking needs API 31, this is ${Build.VERSION.SDK_INT}",
                null,
            )
            return
        }

        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val overlayPng = call.argument<ByteArray>("overlayPng")

        if (inputPath.isNullOrEmpty() || outputPath.isNullOrEmpty() ||
            overlayPng == null || overlayPng.isEmpty()
        ) {
            result.error("bad_input", "inputPath, outputPath and overlayPng are required", null)
            return
        }
        val inputFile = File(inputPath)
        if (!inputFile.isFile || inputFile.length() == 0L) {
            result.error("bad_input", "input video not readable: $inputPath", null)
            return
        }
        if (activeExport != null) {
            // One export at a time -> the caller retries after the current share finishes, and nothing queues natively.
            result.error("transform_failed", "busy", null)
            return
        }

        val overlayBitmap = try {
            BitmapFactory.decodeByteArray(overlayPng, 0, overlayPng.size)
                ?: throw IllegalArgumentException("overlayPng did not decode")
        } catch (e: Throwable) {
            // Throwable, not Exception -> a full-frame decode can OOM, and an OOM here must degrade to a plain share.
            result.error("bad_input", "overlayPng is not a decodable image: ${e.message}", null)
            return
        }

        try {
            File(outputPath).parentFile?.mkdirs()

            // Alpha is pre-baked into the PNG -> a plain full-frame static overlay is the whole job, no anchor or scale.
            val overlay = BitmapOverlay.createStaticBitmapOverlay(overlayBitmap)
            val effects = Effects(
                /* audioProcessors = */ emptyList(),
                /* videoEffects = */ listOf(OverlayEffect(listOf(overlay))),
            )
            val editedItem = EditedMediaItem.Builder(MediaItem.fromUri(toFileUri(inputFile)))
                .setEffects(effects)
                .build()

            val transformer = Transformer.Builder(context)
                .addListener(exportListener())
                .build()

            // Registered BEFORE start() -> the listener resolves the call through it.
            activeExport = ActiveExport(transformer, outputPath, result)
            transformer.start(editedItem, outputPath)
        } catch (e: Throwable) {
            // Throwable, NOT Exception -> androidx/media#2535 threw NoClassDefFoundError straight out of start().
            Log.e(TAG, "watermark start failed", e)
            activeExport = null
            File(outputPath).delete()
            result.error("transform_failed", e.message ?: "could not start export", null)
        }
    }

    private fun exportListener(): Transformer.Listener = object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
            if (!loggedAudioProcess) {
                loggedAudioProcess = true
                val audio = when (exportResult.audioConversionProcess) {
                    ExportResult.CONVERSION_PROCESS_TRANSMUXED -> "TRANSMUXED"
                    ExportResult.CONVERSION_PROCESS_TRANSCODED -> "TRANSCODED"
                    ExportResult.CONVERSION_PROCESS_TRANSMUXED_AND_TRANSCODED ->
                        "TRANSMUXED_AND_TRANSCODED"
                    else -> "NA"
                }
                Log.i(TAG, "export audio conversion: $audio")
            }
            finish { it.result.success(it.outputPath) }
        }

        override fun onError(
            composition: Composition,
            exportResult: ExportResult,
            exportException: ExportException,
        ) {
            Log.e(TAG, "export failed", exportException)
            finish {
                // A torn half-written MP4 must never be handed to a share sheet.
                File(it.outputPath).delete()
                it.result.error(
                    "transform_failed",
                    exportException.message ?: exportException.errorCodeName,
                    null,
                )
            }
        }
    }

    private inline fun finish(reply: (ActiveExport) -> Unit) {
        val export = activeExport ?: return
        activeExport = null
        if (export.replied) return
        export.replied = true
        try {
            reply(export)
        } catch (e: Throwable) {
            // A dead engine's Result can throw -> the export itself has already ended.
            Log.w(TAG, "could not deliver export result", e)
        }
    }

    private fun toFileUri(file: File): android.net.Uri = android.net.Uri.fromFile(file)

    fun dispose() {
        val export = activeExport ?: return
        activeExport = null
        try {
            export.transformer.cancel()
        } catch (e: Throwable) {
            Log.w(TAG, "cancel on dispose failed", e)
        }
        File(export.outputPath).delete()
        // No result.error here -> the engine is going away and the Result with it.
    }
}
