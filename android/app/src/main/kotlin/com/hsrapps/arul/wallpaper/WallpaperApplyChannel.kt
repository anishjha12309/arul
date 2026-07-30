package com.hsrapps.arul.wallpaper

import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
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
 * Channel: `com.hsrapps.arul/wallpaper`
 * Methods:
 *  - setImageWallpaper { filePath, target } → ImageWallpaperManager (static)
 *  - setVideoWallpaper { filePath, enableAudio, loop } → persist MP4 to filesDir,
 *    save prefs, then ALWAYS open the system live-wallpaper preview/chooser
 *    pointing at our service — the user makes the final "Set" tap there, every
 *    time (deliberate product decision; no silent in-place swap). We can't
 *    observe the chooser's result, so success only means "chooser opened".
 *
 * Adopted/trimmed from the vendored flutter_wallpaper_plus WallpaperMethodHandler.
 */
class WallpaperApplyChannel(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrapps.arul/wallpaper"
        private const val TAG = "WallpaperApplyChannel"
        private const val LIVE_VIDEO_DIR_NAME = "arul_live_video"
        private const val ACTIVE_LIVE_VIDEO_BASENAME = "active_live_video"
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

    private fun handleSetVideoWallpaper(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        val enableAudio = call.argument<Boolean>("enableAudio") ?: false
        val loop = call.argument<Boolean>("loop") ?: true

        if (filePath.isNullOrBlank()) {
            result.error("sourceNotFound", "filePath is required", null)
            return
        }

        if (!supportsLiveWallpaper()) {
            result.error(
                "unsupported",
                "Live wallpapers are not supported on this device.",
                null,
            )
            return
        }

        scope.launch {
            try {
                val source = File(filePath)
                if (!source.exists() || source.length() == 0L) {
                    safeError(result, "sourceNotFound", "Video file not found: $filePath")
                    return@launch
                }

                val persisted = persistVideoForWallpaperService(source)
                saveVideoWallpaperConfig(persisted, enableAudio, loop)

                // ALWAYS the system preview/chooser — even when our service is
                // already the active wallpaper. The user confirms with the OS
                // "Set" button every time; no silent in-place swap.
                launchLiveWallpaperChooser()
                // Success = chooser opened. We can't observe the user's choice.
                safeSuccess(result, null)
            } catch (e: Exception) {
                // Full exception stays in logcat; Dart shows only this authored message.
                Log.e(TAG, "setVideoWallpaper failed", e)
                safeError(result, "applyFailed", "Couldn't set live wallpaper. Please try again.")
            }
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
     */
    private fun launchLiveWallpaperChooser() {
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
            return
        } catch (e: Exception) {
            Log.w(TAG, "Direct live-wallpaper chooser failed; trying fallback", e)
        }

        try {
            val fallback = Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(fallback)
        } catch (e: Exception) {
            Log.e(TAG, "Fallback live-wallpaper chooser also failed", e)
            throw IllegalStateException(
                "Could not open the wallpaper picker; this device may not support live wallpapers.",
            )
        }
    }

    private fun supportsLiveWallpaper(): Boolean =
        context.packageManager.hasSystemFeature("android.software.live_wallpaper")
}
