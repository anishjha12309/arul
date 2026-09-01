package com.hsrutility.arul.wallpaper

import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.hsrutility.arul.BuildConfig
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/**
 * MethodChannel handler for wallpaper apply, owned by the app (no plugin dep).
 *
 * The Dart layer ([wallpaper_apply_service.dart]) has already fetched a signed
 * URL and DOWNLOADED the media to a LOCAL file before calling here, so this
 * handler never touches the network — it only reads local files. That keeps the
 * native side small and the entitlement gate where it belongs (the Worker).
 *
 * Channel: `com.hsrutility.arul/wallpaper`
 * Methods:
 *  - setImageWallpaper { filePath, target } → ImageWallpaperManager (static)
 *  - setVideoWallpaper { filePath, enableAudio, loop } → persist MP4 to filesDir,
 *    save prefs, then ALWAYS open the system live-wallpaper preview/chooser
 *    pointing at our service — the user makes the final "Set" tap there, every
 *    time (deliberate product decision; no silent in-place swap). We can't
 *    observe the chooser's result, so success only means "chooser opened".
 *    On a device where live apply is DEFINITIVELY impossible it applies the
 *    clip's first frame as a static wallpaper instead — see
 *    [handleSetVideoWallpaper].
 *
 * Adopted/trimmed from the vendored flutter_wallpaper_plus WallpaperMethodHandler.
 */
class WallpaperApplyChannel(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/wallpaper"
        private const val TAG = "WallpaperApplyChannel"
        private const val LIVE_VIDEO_DIR_NAME = "arul_live_video"
        private const val ACTIVE_LIVE_VIDEO_BASENAME = "active_live_video"

        // setVideoWallpaper's success payload. The result used to be null, which
        // made "chooser opened" and "we applied the poster instead"
        // indistinguishable to Dart; the two need different UI, different
        // pending-flag handling and different analytics.
        private const val OUTCOME_CHOOSER = "chooser"
        private const val OUTCOME_STATIC_FALLBACK = "staticFallback"

        // The ONLY two signals that may route a live apply to the static
        // fallback. Both mean live apply cannot happen on this device AT ALL.
        private const val REASON_FEATURE_MISSING = "featureMissing"
        private const val REASON_CHOOSER_UNAVAILABLE = "chooserUnavailable"
    }

    // Application-scoped, NOT Activity-scoped. Critical: applying a STATIC
    // wallpaper (setStream/setBitmap) is itself what triggers the Android 12+
    // wallpaper-change Activity RELAUNCH (Material You color re-extraction via the
    // runtime-resource-overlay path — this is NOT a config change and CANNOT be
    // opted out of via android:configChanges; see CommonsWare 2021-10-31). If the
    // apply coroutine lived on an Activity-tied scope, that relaunch would cancel
    // it MID-WRITE (CancellationException: Activity destroyed), risking a
    // half-applied wallpaper and a dropped result callback. A SupervisorJob on
    // Dispatchers.Default that we do NOT cancel on dispose() lets the native write
    // run to completion across the relaunch. Uses applicationContext so it never
    // holds the destroyed Activity.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Posts MethodChannel result callbacks back to the main thread. */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Set in dispose() so result callbacks become no-ops once the engine is gone. */
    @Volatile
    private var disposed = false

    private val imageWallpaperManager: ImageWallpaperManager by lazy {
        ImageWallpaperManager(context)
    }

    /**
     * MethodChannel results MUST be delivered on the main thread, and invoking one
     * after the Flutter engine is destroyed throws. The apply runs on
     * Dispatchers.Default and can outlive the Activity (see [scope]), so every
     * result goes through here: posted to the main thread and skipped if disposed.
     */
    private fun safeSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { if (!disposed) runCatching { result.success(value) } }
    }

    private fun safeError(
        result: MethodChannel.Result,
        code: String,
        message: String?,
    ) {
        mainHandler.post { if (!disposed) runCatching { result.error(code, message, null) } }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setImageWallpaper" -> handleSetImageWallpaper(call, result)
            "setVideoWallpaper" -> handleSetVideoWallpaper(call, result)
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        // Deliberately do NOT cancel [scope]: a static apply's setStream IS what
        // relaunches the Activity (which calls this), so cancelling here would
        // abort the wallpaper write in flight. The work is application-scoped and
        // finishes on its own; the result callback just becomes a no-op once the
        // engine is gone (the Dart side already moved on via the pending-apply
        // flow). The SupervisorJob is GC'd with the channel after the write ends.
        disposed = true
    }

    // ── Static image ───────────────────────────────────────────────────────────

    private fun handleSetImageWallpaper(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        val target = call.argument<String>("target") ?: "both"

        if (filePath.isNullOrBlank()) {
            result.error("sourceNotFound", "filePath is required", null)
            return
        }

        scope.launch {
            try {
                imageWallpaperManager.setWallpaper(File(filePath), target)
                safeSuccess(result, null)
            } catch (e: WallpaperApplyException) {
                safeError(result, e.code, e.message)
            } catch (e: Exception) {
                // Full exception stays in logcat; Dart shows only this authored message.
                Log.e(TAG, "setImageWallpaper unexpected", e)
                safeError(result, "unknown", "Couldn't apply wallpaper. Please try again.")
            }
        }
    }

    // ── Live video ─────────────────────────────────────────────────────────────

    /**
     * Persists the clip, then opens the system chooser — or, on a device where
     * live apply is DEFINITIVELY impossible, applies the clip's own first frame
     * as a static wallpaper so the user is not left at a dead end (the manifest
     * has always declared android.software.live_wallpaper optional; this is the
     * degradation it promises).
     *
     * EXACTLY TWO signals may take the fallback, and both mean "no live
     * wallpaper can ever be set on this device":
     *  1. [supportsLiveWallpaper] is false — the platform feature is absent.
     *  2. BOTH chooser intents throw from startActivity — nothing on the
     *     device handles either one.
     *
     * Everything else here — a missing or empty source, an IO failure while
     * persisting, a prefs failure — keeps its own error code and does NOT fall
     * back. Those are retryable faults on devices that CAN do live wallpapers,
     * and quietly applying a still image instead would hide them; a normal
     * device silently routed to static is the one outcome this must never
     * produce. For the same reason [OemPolicy] is not consulted: it lists
     * xiaomi/redmi for a setBitmap write quirk, while most Redmi devices apply
     * live wallpapers fine, so a manufacturer-keyed trigger would misroute a
     * whole vendor family.
     *
     * Detection is attempt-and-degrade, never query-and-assume: the try/catch
     * around startActivity IS the probe. No resolveActivity pre-flight —
     * Google's package-visibility guidance says to invoke the intent and handle
     * ActivityNotFoundException, because startActivity needs no package
     * visibility while the query methods ARE filtered from API 30, so a
     * pre-flight can answer "no handler" on a device where the launch would
     * have worked.
     */
    private fun handleSetVideoWallpaper(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        val enableAudio = call.argument<Boolean>("enableAudio") ?: false
        val loop = call.argument<Boolean>("loop") ?: true
        val forcedFallback = debugForcedFallback(call.argument<String>("debugForceFallback"))

        if (filePath.isNullOrBlank()) {
            result.error("sourceNotFound", "filePath is required", null)
            return
        }

        scope.launch {
            try {
                val source = File(filePath)
                if (!source.exists() || source.length() == 0L) {
                    safeError(result, "sourceNotFound", "Video file not found: $filePath")
                    return@launch
                }

                // Signal 1. Checked before the copy and the prefs write: with no
                // live-wallpaper feature there is no service to configure.
                if (forcedFallback == REASON_FEATURE_MISSING || !supportsLiveWallpaper()) {
                    applyFirstFrameFallback(source, REASON_FEATURE_MISSING, result)
                    return@launch
                }

                val persisted = persistVideoForWallpaperService(source)
                saveVideoWallpaperConfig(persisted, enableAudio, loop)

                // ALWAYS the system preview/chooser — even when our service is
                // already the active wallpaper. The user confirms with the OS
                // "Set" button every time; no silent in-place swap.
                // Signal 2: false = both intents threw.
                if (forcedFallback == REASON_CHOOSER_UNAVAILABLE ||
                    !launchLiveWallpaperChooser()
                ) {
                    applyFirstFrameFallback(source, REASON_CHOOSER_UNAVAILABLE, result)
                    return@launch
                }
                // Success = chooser opened. We can't observe the user's choice.
                safeSuccess(result, mapOf("outcome" to OUTCOME_CHOOSER))
            } catch (e: WallpaperApplyException) {
                // The fallback's own failures (device policy, a rejected write)
                // keep their real codes — masking them as applyFailed would make
                // the new Dart-side failure event unreadable.
                Log.e(TAG, "setVideoWallpaper failed (${e.code})", e)
                safeError(result, e.code, e.message)
            } catch (e: Exception) {
                // Full exception stays in logcat; Dart shows only this authored message.
                Log.e(TAG, "setVideoWallpaper failed", e)
                safeError(result, "applyFailed", "Couldn't set live wallpaper. Please try again.")
            }
        }
    }

    /**
     * The degradation: the clip's own first frame, applied as a static
     * wallpaper on home and lock. Never the thumbs/ poster — that object is a
     * 640-wide q:v 3 JPEG built for a feed card and would reach the home screen
     * upscaled and soft. The full-quality still IS frame 0 of the MP4 already
     * sitting in the app's temp dir, and the chain from here (decoded frame →
     * centre-cropped bitmap → setBitmap, which the OS stores as a PNG) is
     * lossless.
     */
    private suspend fun applyFirstFrameFallback(
        source: File,
        reason: String,
        result: MethodChannel.Result,
    ) {
        val frame = extractFirstFrame(source)
            ?: throw WallpaperApplyException(
                "applyFailed",
                "Couldn't read this wallpaper's first frame.",
            )
        try {
            imageWallpaperManager.setWallpaperFromBitmap(frame)
        } finally {
            if (!frame.isRecycled) frame.recycle()
        }
        Log.i(TAG, "Live apply degraded to static first frame ($reason)")
        safeSuccess(
            result,
            mapOf("outcome" to OUTCOME_STATIC_FALLBACK, "reason" to reason),
        )
    }

    /**
     * Frame 0 of [source], or null when the retriever cannot decode one.
     *
     * OPTION_CLOSEST_SYNC at t=0 is EXACT for our faststart H.264 clips (the
     * first frame is the sync frame) and is the cheap option — OPTION_CLOSEST
     * is documented as the higher-overhead one. The no-arg getFrameAtTime() is
     * wrong here: it returns "a representative frame at any time position", not
     * frame 0. From API 30 the BitmapParams overload asks for ARGB_8888; below
     * that "the device will choose the actual Bitmap.Config", an accepted and
     * documented degradation. The import pipeline is what guarantees frame 0 is
     * representative and non-black (docs/media-conventions.md).
     *
     * Null is a real possibility by contract, so the caller surfaces the normal
     * error rather than substituting anything — a half-outcome (clip persisted,
     * no wallpaper, no error) would be worse than the dead end this replaces.
     */
    private suspend fun extractFirstFrame(source: File): Bitmap? =
        withContext(Dispatchers.IO) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(source.absolutePath)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    retriever.getFrameAtTime(
                        0L,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        MediaMetadataRetriever.BitmapParams(),
                    )
                } else {
                    retriever.getFrameAtTime(0L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                }
            } catch (e: Exception) {
                Log.e(TAG, "First-frame extraction failed: ${source.name}", e)
                null
            } finally {
                try {
                    retriever.release()
                } catch (e: Exception) {
                    Log.w(TAG, "MediaMetadataRetriever release failed", e)
                }
            }
        }

    /**
     * Test seam for the two fallback reasons, so both can be walked on a device
     * that is perfectly capable of live wallpapers. Dart passes
     * debugForceFallback from --dart-define=DEBUG_LIVE_WALLPAPER_FALLBACK=...;
     * the BuildConfig.DEBUG gate makes this dead code in every release build,
     * which is what stops a shipped install being talked into the fallback.
     */
    private fun debugForcedFallback(raw: String?): String? {
        if (!BuildConfig.DEBUG || raw.isNullOrBlank()) return null
        return when (raw) {
            REASON_FEATURE_MISSING, REASON_CHOOSER_UNAVAILABLE -> raw
            else -> null
        }
    }

    /**
     * Copies the source MP4 into app-internal storage under a UNIQUE filename per
     * apply, returns the destination. Unique names (not a fixed path) avoid file
     * contention: when a second live wallpaper is applied, the previous service
     * engine still has the previous file open for decoding — overwriting that
     * same path corrupts the running decoder on budget devices. A fresh name
     * leaves the running file untouched. Cleanup is conservative: delete every
     * other live-video file EXCEPT the new one and the previously-active one (the
     * running engine may still hold it open), capping storage at ~2 files.
     */
    private suspend fun persistVideoForWallpaperService(sourceFile: File): File =
        withContext(Dispatchers.IO) {
            val dir = File(context.filesDir, LIVE_VIDEO_DIR_NAME)
            if (!dir.exists() && !dir.mkdirs()) {
                throw IllegalStateException("Could not create live wallpaper storage directory.")
            }

            val servicePrefs = context.getSharedPreferences(
                ArulVideoWallpaperService.PREFS_NAME,
                Context.MODE_PRIVATE,
            )
            val previousActivePath =
                servicePrefs.getString(ArulVideoWallpaperService.KEY_VIDEO_PATH, null)

            val ext = sourceFile.extension
                .takeIf { it.isNotBlank() }
                ?.lowercase(Locale.US)
                ?: "mp4"
            val uniqueName =
                "${ACTIVE_LIVE_VIDEO_BASENAME}_${System.currentTimeMillis()}.$ext"
            val dest = File(dir, uniqueName)
            val temp = File(dir, "$uniqueName.tmp")

            sourceFile.inputStream().use { input ->
                temp.outputStream().use { output -> input.copyTo(output) }
            }
            if (!temp.exists() || temp.length() == 0L) {
                temp.delete()
                throw IllegalStateException("Prepared live wallpaper file is empty.")
            }
            if (!temp.renameTo(dest)) {
                temp.copyTo(dest, overwrite = true)
                temp.delete()
            }

            // Lazily clean old files — never the new one nor the previously-
            // active one (the running engine may still hold it open).
            dir.listFiles()
                ?.filter { f ->
                    f.name.startsWith(ACTIVE_LIVE_VIDEO_BASENAME) &&
                            f.absolutePath != dest.absolutePath &&
                            f.absolutePath != previousActivePath
                }
                ?.forEach { stale ->
                    if (!stale.delete()) {
                        Log.w(TAG, "Failed to delete stale live file: ${stale.absolutePath}")
                    }
                }

            dest
        }

    private fun saveVideoWallpaperConfig(file: File, enableAudio: Boolean, loop: Boolean) {
        context.getSharedPreferences(
            ArulVideoWallpaperService.PREFS_NAME,
            Context.MODE_PRIVATE,
        ).edit()
            .putString(ArulVideoWallpaperService.KEY_VIDEO_PATH, file.absolutePath)
            .putBoolean(ArulVideoWallpaperService.KEY_ENABLE_AUDIO, enableAudio)
            .putBoolean(ArulVideoWallpaperService.KEY_LOOP, loop)
            .commit()
    }

    /**
     * Opens the system live-wallpaper chooser pointing straight at our service
     * (so the user lands on a preview of our wallpaper with a "Set" button), with
     * a generic-chooser fallback for OEMs that reject the direct component intent.
     *
     * Returns false when BOTH launches throw — nothing on this device handles
     * either chooser intent, which is one of the two signals
     * [handleSetVideoWallpaper] is allowed to degrade on. It reports rather than
     * throws precisely so that outcome stays distinguishable from the ordinary
     * failures around it.
     */
    private fun launchLiveWallpaperChooser(): Boolean {
        try {
            val component = ComponentName(
                context.packageName,
                ArulVideoWallpaperService::class.java.name,
            )
            val intent = Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER).apply {
                putExtra(WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT, component)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            return true
        } catch (e: Exception) {
            Log.w(TAG, "Direct live-wallpaper chooser failed; trying fallback", e)
        }

        return try {
            val fallback = Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(fallback)
            true
        } catch (e: Exception) {
            Log.e(TAG, "Fallback live-wallpaper chooser also failed", e)
            false
        }
    }

    private fun supportsLiveWallpaper(): Boolean =
        context.packageManager.hasSystemFeature("android.software.live_wallpaper")
}
