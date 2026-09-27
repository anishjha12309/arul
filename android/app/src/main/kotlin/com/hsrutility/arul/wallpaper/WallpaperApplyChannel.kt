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

// Dart has already fetched a signed URL and DOWNLOADED the media before calling here.
// So this handler never touches the network -> it only reads local files, and the entitlement gate stays in the Worker.
class WallpaperApplyChannel(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/wallpaper"
        private const val TAG = "WallpaperApplyChannel"
        private const val LIVE_VIDEO_DIR_NAME = "arul_live_video"
        private const val ACTIVE_LIVE_VIDEO_BASENAME = "active_live_video"

        private const val OUTCOME_CHOOSER = "chooser"
        private const val OUTCOME_STATIC_FALLBACK = "staticFallback"

        private const val REASON_FEATURE_MISSING = "featureMissing"
        private const val REASON_CHOOSER_UNAVAILABLE = "chooserUnavailable"
    }

    // Application-scoped, NEVER Activity-scoped -> a static apply is itself what relaunches the Activity on Android 12+.
    // Material You re-extracts colour through the runtime-resource-overlay path.
    // That is NOT a config change and CANNOT be opted out of via android:configChanges.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Set in dispose() so result callbacks become no-ops once the engine is gone. */
    @Volatile
    private var disposed = false

    private val imageWallpaperManager: ImageWallpaperManager by lazy {
        ImageWallpaperManager(context)
    }

    // The apply runs on Dispatchers.Default and can outlive the Activity -> every result posts through here.
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
        // Deliberately do NOT cancel [scope] -> a static apply's setStream IS what relaunches the Activity that calls this.
        // Cancelling here would abort the wallpaper write in flight.
        disposed = true
    }


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
                // The full exception stays in logcat -> Dart shows only this authored message.
                Log.e(TAG, "setImageWallpaper unexpected", e)
                safeError(result, "unknown", "Couldn't apply wallpaper. Please try again.")
            }
        }
    }


    // On a device where live apply is DEFINITIVELY impossible it applies the clip's own first frame instead.
    // The manifest has always declared android.software.live_wallpaper optional -> this is the degradation it promises.
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

                // Signal 1, checked before the copy and the prefs write -> with no live-wallpaper feature there is no service.
                if (forcedFallback == REASON_FEATURE_MISSING || !supportsLiveWallpaper()) {
                    applyFirstFrameFallback(source, REASON_FEATURE_MISSING, result)
                    return@launch
                }

                val persisted = persistVideoForWallpaperService(source)
                saveVideoWallpaperConfig(persisted, enableAudio, loop)

                // Signal 2 -> false means both intents threw.
                if (forcedFallback == REASON_CHOOSER_UNAVAILABLE ||
                    !launchLiveWallpaperChooser()
                ) {
                    applyFirstFrameFallback(source, REASON_CHOOSER_UNAVAILABLE, result)
                    return@launch
                }
                safeSuccess(result, mapOf("outcome" to OUTCOME_CHOOSER))
            } catch (e: WallpaperApplyException) {
                // The fallback's own failures keep their REAL codes -> masking them as applyFailed hides device policy.
                Log.e(TAG, "setVideoWallpaper failed (${e.code})", e)
                safeError(result, e.code, e.message)
            } catch (e: Exception) {
                // The full exception stays in logcat -> Dart shows only this authored message.
                Log.e(TAG, "setVideoWallpaper failed", e)
                safeError(result, "applyFailed", "Couldn't set live wallpaper. Please try again.")
            }
        }
    }

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

    // OPTION_CLOSEST_SYNC at t=0 is EXACT for faststart H.264 clips, where the first frame IS the sync frame.
    // The no-arg getFrameAtTime() is WRONG here -> it returns a representative frame at any position, not frame 0.
    // Null is a real possibility BY CONTRACT -> the caller surfaces the normal error rather than substituting anything.
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

    // Test seam for the two fallback reasons -> both can be walked on a device perfectly capable of live wallpapers.
    // Dart passes debugForceFallback from --dart-define=DEBUG_LIVE_WALLPAPER_FALLBACK=...
    // The BuildConfig.DEBUG gate makes this dead code in every release build -> a shipped install cannot be talked into it.
    private fun debugForcedFallback(raw: String?): String? {
        if (!BuildConfig.DEBUG || raw.isNullOrBlank()) return null
        return when (raw) {
            REASON_FEATURE_MISSING, REASON_CHOOSER_UNAVAILABLE -> raw
            else -> null
        }
    }

    // A unique name, never a fixed path -> the previous engine still has the previous file open for decoding.
    // Overwriting that same path corrupts the running decoder on budget devices.
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

            // Lazily clean old files -> never the new one, and never the previously-active one a running engine may hold.
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

    // A generic-chooser fallback covers OEMs that reject the direct component intent.
    // Returns FALSE when both launches throw -> nothing on this device handles either chooser intent.
    // It reports rather than throws -> that keeps this outcome distinguishable from the ordinary failures around it.
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
