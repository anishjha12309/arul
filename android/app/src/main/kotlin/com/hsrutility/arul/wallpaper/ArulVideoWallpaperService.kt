package com.hsrutility.arul.wallpaper

import android.content.SharedPreferences
import android.service.wallpaper.WallpaperService
import android.util.Log
import android.view.SurfaceHolder
import java.io.File

// The system binds to THIS service when the user selects the app as their live wallpaper.
// It loops the downloaded MP4 via [VideoRenderer], independently of the Flutter app -> it survives an app kill.
// Config (video path, audio, loop) is written to SharedPreferences by [WallpaperApplyChannel].
// It is read on surface creation, so the service starts correctly even after a process kill.
// It is also OBSERVED live -> Android ignores a re-Set of the already-active component and never recreates the engine.
// So a prefs change is the only signal a running engine gets that a new video was applied.
// ONE video at a time, deliberately -> every engine, home or lock, follows the single shared [KEY_VIDEO_PATH].
// No per-surface pinning -> identical behaviour on every Android version.
// Every callback is wrapped -> a player must never crash the service.
// Each engine plays its OWN private copy -> dual home/lock engines and a mid-run re-apply never yank a file from a decoder.
class ArulVideoWallpaperService : WallpaperService() {

    companion object {
        private const val TAG = "ArulWallpaperSvc"

        /** SharedPreferences file shared with [WallpaperApplyChannel], which is the writer. */
        const val PREFS_NAME = "arul_wallpaper_prefs"
        const val KEY_VIDEO_PATH = "video_path"
        const val KEY_ENABLE_AUDIO = "enable_audio"
        const val KEY_LOOP = "loop"

        /** Directory under filesDir holding running engines' private copies. */
        const val ENGINE_PRIVATE_DIR = "arul_live_active"

        /** Orphaned private copies older than this are swept on engine start. */
        private const val ORPHAN_SWEEP_AGE_MS = 60L * 60L * 1000L // 1 hour
    }

    override fun onCreateEngine(): Engine = VideoWallpaperEngine()

    inner class VideoWallpaperEngine : Engine() {

        private var videoRenderer: VideoRenderer? = null

        /** Established once per engine; reused across surface recreations. */
        private var enginePrivatePath: String? = null

        /** The prefs source the private copy was adopted from -> the staleness check reads it. */
        private var adoptedSourcePath: String? = null

        private var surfaceCreated = false

        private val prefs: SharedPreferences by lazy {
            applicationContext.getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        }

        // Applying a new wallpaper while this service is ALREADY active never recreates the engine.
        // Android logs "Changing to the same component, ignoring" -> the prefs write is the only signal an engine gets.
        // Same process, so the listener is reliable -> react to it here.
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

        // Adopt a private copy of the new source FIRST -> a failed copy keeps the old video playing.
        // Only then drop the stale copy and swap the running player in place.
        // Unlinking the old copy mid-decode is safe because the decoder's fd stays valid -> overwriting it would not be.
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
                // The first apply landed on a blank-surface engine -> there was no video at start.
                startRenderer(surfaceHolder)
            }
        }

        // Returns this engine's private copy, established once and reused across surface recreations.
        // Kept IN MEMORY, never in prefs -> sibling home/lock engines must not share or delete each other's copy.
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
            // Video wallpapers do not scroll -> intentionally empty.
        }
    }
}
