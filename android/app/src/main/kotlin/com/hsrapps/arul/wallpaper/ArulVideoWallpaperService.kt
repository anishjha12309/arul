package com.hsrapps.arul.wallpaper

import android.content.SharedPreferences
import android.service.wallpaper.WallpaperService
import android.util.Log
import android.view.SurfaceHolder
import java.io.File

/**
 * The live (video) wallpaper service. When the user selects Arul as their live
 * wallpaper, the system binds to THIS service and it loops the downloaded MP4 on
 * the home screen via [VideoRenderer] (Media3 ExoPlayer), running independently
 * of the Flutter app (survives app kill).
 *
 * Declared in AndroidManifest.xml as `.wallpaper.ArulVideoWallpaperService`
 * (exported, BIND_WALLPAPER, @xml/video_wallpaper).
 *
 * Config (video path + audio + loop) is written to SharedPreferences by
 * [WallpaperApplyChannel], read here on surface creation (so the service starts
 * correctly even after an app/process kill) AND observed live — a running engine
 * swaps its video when a new one is applied, because Android ignores a re-Set of
 * the already-active component and never recreates the engine.
 *
 * One video at a time (2026-07-05, deliberate): every engine — home, lock, or
 * both — follows the single shared [KEY_VIDEO_PATH]. No per-surface pinning;
 * identical behavior on every Android version.
 *
 * Adopted from the vendored flutter_wallpaper_plus VideoWallpaperService. Robust
 * by construction: every callback is wrapped, players never crash the service,
 * each engine plays its OWN private copy of the video (so Samsung-style dual
 * home/lock engines and a mid-run re-apply never yank a file from a live decoder).
 */
class ArulVideoWallpaperService : WallpaperService() {

    companion object {
        private const val TAG = "ArulWallpaperSvc"

        /** SharedPreferences file shared with [WallpaperApplyChannel] (writer). */
        const val PREFS_NAME = "arul_wallpaper_prefs"
        const val KEY_VIDEO_PATH = "video_path"
        const val KEY_ENABLE_AUDIO = "enable_audio"
        const val KEY_LOOP = "loop"

        /** Directory (under filesDir) holding running engines' private copies. */
        const val ENGINE_PRIVATE_DIR = "arul_live_active"

        /** Orphaned private copies older than this are swept on engine start. */
        private const val ORPHAN_SWEEP_AGE_MS = 60L * 60L * 1000L // 1 hour
    }

    override fun onCreateEngine(): Engine = VideoWallpaperEngine()

    inner class VideoWallpaperEngine : Engine() {

        private var videoRenderer: VideoRenderer? = null

        /** Established once per engine; reused across surface recreations. */
        private var enginePrivatePath: String? = null

        /** The prefs source the private copy was adopted from (staleness check). */
        private var adoptedSourcePath: String? = null

        private var surfaceCreated = false

        private val prefs: SharedPreferences by lazy {
            applicationContext.getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        }

        /**
         * Applying a new live wallpaper while this service is ALREADY the active
         * system wallpaper never recreates the engine — Android ignores a re-Set
         * of the same component ("Changing to the same component, ignoring"). The
         * prefs write by [WallpaperApplyChannel] is therefore the only signal a
         * running engine gets, so react to it here (same process, so the listener
         * is reliable).
         */
        private val prefsListener =
            SharedPreferences.OnSharedPreferenceChangeListener { changed, key ->
                try {
                    when (key) {
                        KEY_VIDEO_PATH -> onSourceVideoChanged()
                        KEY_ENABLE_AUDIO ->
                            videoRenderer?.audioEnabled =
                                changed.getBoolean(KEY_ENABLE_AUDIO, false)
                        KEY_LOOP ->
                            videoRenderer?.loopEnabled = changed.getBoolean(KEY_LOOP, true)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error applying pref change ($key)", e)
                }
            }

        /** The single source video every engine follows. */
        private fun configuredSourcePath(): String? =
            prefs.getString(KEY_VIDEO_PATH, null)

        override fun onCreate(surfaceHolder: SurfaceHolder?) {
            super.onCreate(surfaceHolder)
            // Pass touches through to the launcher.
            setTouchEventsEnabled(false)
            prefs.registerOnSharedPreferenceChangeListener(prefsListener)
        }

        override fun onSurfaceCreated(holder: SurfaceHolder) {
            super.onSurfaceCreated(holder)
            surfaceCreated = true
            startRenderer(holder)
        }

        private fun startRenderer(holder: SurfaceHolder) {
            try {
                val videoPath = resolveEnginePrivatePath()
                val enableAudio = prefs.getBoolean(KEY_ENABLE_AUDIO, false)
                val loop = prefs.getBoolean(KEY_LOOP, true)

                if (videoPath.isNullOrBlank()) {
                    Log.w(TAG, "No playable video for this engine; showing blank surface.")
                    return
                }

                videoRenderer = VideoRenderer(applicationContext).apply {
                    audioEnabled = enableAudio
                    loopEnabled = loop
                    initialize(videoPath, holder)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error starting renderer", e)
            }
        }

        /**
         * A new source video was applied. Adopt a private copy of it FIRST (so a
         * failed copy keeps the old video playing), then drop the stale copy and
         * swap the running player in place. Unlinking the old copy mid-decode is
         * safe (the decoder's fd stays valid); overwriting it would not be.
         */
        private fun onSourceVideoChanged() {
            val newSource = configuredSourcePath()
            if (newSource == adoptedSourcePath) return

            val stalePrivate = enginePrivatePath
            enginePrivatePath = null
            val newPrivate = resolveEnginePrivatePath()
            if (newPrivate == null) {
                enginePrivatePath = stalePrivate // keep playing what we have
                return
            }
            if (stalePrivate != null && stalePrivate != newPrivate) {
                File(stalePrivate).delete()
            }

            if (!surfaceCreated) return // next onSurfaceCreated picks it up
            val renderer = videoRenderer
            if (renderer != null) {
                renderer.swapVideo(newPrivate, surfaceHolder)
            } else {
                // First apply landed on a blank-surface engine (no video at start).
                startRenderer(surfaceHolder)
            }
        }

        /**
         * Returns this engine's private video copy, establishing it once and
         * reusing it across surface recreations. Kept in-memory (not in prefs) so
         * sibling engines (Samsung home/lock) never share or delete each other's
         * copy via a common key.
         */
        private fun resolveEnginePrivatePath(): String? {
            enginePrivatePath?.let { existing ->
                if (File(existing).existsNonEmpty()) return existing
            }

            val source = configuredSourcePath()
            if (source.isNullOrBlank() || !File(source).existsNonEmpty()) {
                Log.e(TAG, "No source video to adopt (path=$source)")
                return null
            }

            val copy = copyToEnginePrivate(File(source)) ?: return null
            enginePrivatePath = copy.absolutePath
            adoptedSourcePath = source
            sweepOrphanPrivateCopies(keep = copy.absolutePath)
            return enginePrivatePath
        }

        private fun copyToEnginePrivate(source: File): File? {
            return try {
                val dir = File(applicationContext.filesDir, ENGINE_PRIVATE_DIR)
                if (!dir.exists() && !dir.mkdirs()) {
                    Log.e(TAG, "Could not create engine-private dir")
                    return null
                }
                val ext = source.extension.takeIf { it.isNotBlank() } ?: "mp4"
                val dest = File(dir, "engine_${System.nanoTime()}.$ext")
                source.inputStream().use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
                if (!dest.existsNonEmpty()) {
                    dest.delete()
                    null
                } else {
                    dest
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to copy engine-private video", e)
                null
            }
        }

        private fun sweepOrphanPrivateCopies(keep: String) {
            try {
                val now = System.currentTimeMillis()
                File(applicationContext.filesDir, ENGINE_PRIVATE_DIR)
                    .listFiles()
                    ?.forEach { f ->
                        val isStale = now - f.lastModified() > ORPHAN_SWEEP_AGE_MS
                        if (f.absolutePath != keep && isStale) f.delete()
                    }
            } catch (e: Exception) {
                Log.w(TAG, "Orphan sweep failed (non-critical)", e)
            }
        }

        private fun File.existsNonEmpty(): Boolean = exists() && length() > 0L

        override fun onSurfaceChanged(
            holder: SurfaceHolder,
            format: Int,
            width: Int,
            height: Int
        ) {
            super.onSurfaceChanged(holder, format, width, height)
            try {
                videoRenderer?.onSurfaceChanged(holder)
            } catch (e: Exception) {
                Log.e(TAG, "Error in onSurfaceChanged", e)
            }
        }

        override fun onVisibilityChanged(visible: Boolean) {
            super.onVisibilityChanged(visible)
            try {
                videoRenderer?.onVisibilityChanged(visible)
            } catch (e: Exception) {
                Log.e(TAG, "Error in onVisibilityChanged", e)
            }
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            surfaceCreated = false
            try {
                videoRenderer?.onSurfaceDestroyed()
            } catch (e: Exception) {
                Log.e(TAG, "Error in onSurfaceDestroyed", e)
            }
            super.onSurfaceDestroyed(holder)
        }

        override fun onDestroy() {
            try {
                prefs.unregisterOnSharedPreferenceChangeListener(prefsListener)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to unregister prefs listener", e)
            }
            try {
                videoRenderer?.release()
                videoRenderer = null
            } catch (e: Exception) {
                Log.e(TAG, "Error in onDestroy", e)
            }
            // Delete this engine's private copy now that its player is released.
            try {
                enginePrivatePath?.let { File(it).delete() }
                enginePrivatePath = null
                adoptedSourcePath = null
            } catch (e: Exception) {
                Log.w(TAG, "Failed to clean engine-private copy", e)
            }
            super.onDestroy()
        }

        override fun onOffsetsChanged(
            xOffset: Float,
            yOffset: Float,
            xOffsetStep: Float,
            yOffsetStep: Float,
            xPixelOffset: Int,
            yPixelOffset: Int
        ) {
            // Video wallpapers don't scroll — intentionally empty.
        }
    }
}
