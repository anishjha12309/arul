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

/**
 * Burns the Arul watermark into a live wallpaper's MP4 at SHARE time, natively,
 * via Media3 Transformer — no ffmpeg on device, and the CDN keeps serving the
 * clean original (the watermark exists only in the shared copy).
 *
 * The Dart side renders the ENTIRE overlay (logo + text, positioned, alpha
 * pre-baked) as one full-frame transparent PNG and hands it over as bytes, so
 * this class does zero layout math: decode → static [BitmapOverlay] → re-encode.
 *
 * Contract (the Dart caller is built against exactly this):
 *   channel  com.hsrutility.arul/share_watermark
 *   method   videoWatermarkSupport {} → {supported: Boolean, sdkInt: Int}
 *   method   watermarkVideo {inputPath, outputPath, overlayPng}
 *   success  → outputPath
 *   errors   → "bad_input" (bad args / unreadable input),
 *              "unsupported_api" (below API 31 — see below),
 *              "transform_failed" (export error, or a second call while busy)
 *
 * REQUIRES API 31. Media3's `ExoPlayerAssetLoader.Factory` holds a field, a
 * constructor parameter and a `createAssetLoader` local of type
 * `android.media.metrics.LogSessionId` — an API-31 type — with NO `SDK_INT`
 * guard anywhere in the class (verified in the shipped bytecode of 1.9.2 and
 * 1.10.1; 1.7.1 predates the field and is clean). ART therefore resolves that
 * type on every API level and `Transformer.start()` dies with
 * `NoClassDefFoundError` on Android 11 and below. Upstream: androidx/media#2535,
 * still open. Below API 31 we do NOT export at all and the caller shares the
 * clean original; a pre-Android-12 share is untraced by design.
 *
 * Everything here catches [Throwable], not [Exception]. That is the whole
 * lesson of the crash above: `NoClassDefFoundError` is an `Error`, so a
 * `catch (Exception)` let a library defect past the handler, past Dart's own
 * catch, and out through `Looper.loop()` — killing the app instead of falling
 * back to sharing the original. A watermark must never break the share, and
 * that promise is only real if the net catches Errors too.
 *
 * Only ONE export runs at a time: Transformer holds a hardware decoder AND an
 * encoder for the duration, and on budget SoCs that budget is shared with the
 * feed's preview pool — a concurrent second export is the decoder-starvation
 * bug class this app studiously avoids. Clips are 1024x1824 H.264, well inside
 * 1080p-class hardware encoders; the default encoder factory's fallback stays
 * enabled for the stragglers.
 *
 * Threading: Flutter MethodChannel handlers arrive on the platform main thread,
 * which has a Looper — exactly what [Transformer] requires. Listener callbacks
 * come back on that same thread, so no hopping is needed.
 */
@UnstableApi
class ShareWatermarkChannel(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/share_watermark"
        private const val TAG = "ShareWatermark"
    }

    /**
     * The in-flight export. Doubles as the busy flag AND the GC anchor: nothing
     * else references the Transformer, and an export whose Transformer is
     * collected mid-flight just silently dies.
     */
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

    /**
     * Whether an export can run at all on this device — see the class doc for
     * why API 31 and not a codec probe. The Dart side asks FIRST so it can skip
     * rendering a full 1024x1824 overlay PNG it would only throw away.
     */
    private val videoWatermarkSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    private fun watermarkVideo(call: MethodCall, result: MethodChannel.Result) {
        if (!videoWatermarkSupported) {
            // Defence in depth: the Dart side gates on videoWatermarkSupport,
            // but calling Transformer here would be fatal, not merely wrong, so
            // this never relies on the caller having asked.
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
            // One export at a time — see class doc. The caller retries after the
            // current share finishes; it never queues natively.
            result.error("transform_failed", "busy", null)
            return
        }

        val overlayBitmap = try {
            BitmapFactory.decodeByteArray(overlayPng, 0, overlayPng.size)
                ?: throw IllegalArgumentException("overlayPng did not decode")
        } catch (e: Throwable) {
            // Throwable, not Exception: a full-frame decode can OOM, which is an
            // Error — and an OOM here must degrade to an unwatermarked share.
            result.error("bad_input", "overlayPng is not a decodable image: ${e.message}", null)
            return
        }

        try {
            File(outputPath).parentFile?.mkdirs()

            // Alpha is pre-baked into the PNG, so the plain full-frame static
            // overlay (alphaScale 1, no anchor/scale settings) is the whole job.
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

            // Registered BEFORE start(): the listener resolves the call via this.
            activeExport = ActiveExport(transformer, outputPath, result)
            transformer.start(editedItem, outputPath)
        } catch (e: Throwable) {
            // Throwable, NOT Exception. androidx/media#2535 threw
            // NoClassDefFoundError straight out of Transformer.start() and an
            // `Exception` handler could not see it, so a library defect became
            // a process kill. Anything that escapes start() is a failed export,
            // whatever its supertype.
            Log.e(TAG, "watermark start failed", e)
            activeExport = null
            File(outputPath).delete()
            result.error("transform_failed", e.message ?: "could not start export", null)
        }
    }

    private fun exportListener(): Transformer.Listener = object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
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

    /** Reply exactly once and clear the busy slot, whatever the outcome. */
    private inline fun finish(reply: (ActiveExport) -> Unit) {
        val export = activeExport ?: return
        activeExport = null
        if (export.replied) return
        export.replied = true
        try {
            reply(export)
        } catch (e: Throwable) {
            // A dead engine's Result can throw; the export itself already ended.
            Log.w(TAG, "could not deliver export result", e)
        }
    }

    private fun toFileUri(file: File): android.net.Uri = android.net.Uri.fromFile(file)

    /** Called from MainActivity.cleanUpFlutterEngine — cancel any running export. */
    fun dispose() {
        val export = activeExport ?: return
        activeExport = null
        try {
            export.transformer.cancel()
        } catch (e: Throwable) {
            Log.w(TAG, "cancel on dispose failed", e)
        }
        File(export.outputPath).delete()
        // No result.error here: the engine is going away and the Result with it.
    }
}
