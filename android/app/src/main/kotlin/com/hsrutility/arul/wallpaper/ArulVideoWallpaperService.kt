package com.hsrutility.arul.wallpaper

import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.util.Log
import android.view.SurfaceHolder
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

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
// That copy is megabytes of file IO -> it runs on [ioExecutor], NEVER on the engine's callback thread.
// The framework attaches an engine and delivers onSurfaceChanged on the service's main thread, and a copy
// there on a budget phone's storage was an ANR ("slow IO operations").
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

    /** Private copies, their deletes and the orphan sweep -> one thread, so two engines never contend. */
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onCreateEngine(): Engine = VideoWallpaperEngine()

    override fun onDestroy() {
        ioExecutor.shutdown()
        super.onDestroy()
    }

    /** Queues [task] on [ioExecutor]; false once the service is going and the executor is shut. */
    private fun runIo(task: () -> Unit): Boolean =
        try {
            ioExecutor.execute(task)
            true
        } catch (e: Exception) {
            Log.w(TAG, "IO task rejected", e)
            false
        }

    inner class VideoWallpaperEngine : Engine() {

        private var videoRenderer: VideoRenderer? = null

        /** Established once per engine; reused across surface recreations. */
        private var enginePrivatePath: String? = null

        /** The prefs source the private copy was adopted from -> the staleness check reads it. */
        private var adoptedSourcePath: String? = null

        /** The source a background copy is running for -> a second trigger joins it instead of copying twice. */
        private var adoptingSource: String? = null

        /** Bumped by every adopt and by [onDestroy] -> a copy that lands for a superseded request is dropped. */
        private var adoptGeneration = 0

        private var destroyed = false

        // Set by the first onSurfaceChanged carrying a non-zero size, cleared when the surface goes.
        // Nothing decodes before it: the engine's final width and height arrive with onSurfaceChanged,
        // never with onSurfaceCreated, and a frame rendered into not-yet-final geometry is the visible
        // rescale. The framework always dispatches onSurfaceChanged in the same pass as onSurfaceCreated,
        // so waiting for it costs no start-up time.
        private var surfaceSized = false

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
            // Deliberately does NOT start the renderer -> onSurfaceChanged owns that, once it has geometry.
        }

        // This engine's copy already exists -> start now (a stat, no copy). Otherwise adopt one in the
        // background; [showAdopted] starts the renderer when it lands.
        private fun startRenderer(holder: SurfaceHolder) {
            val existing = enginePrivatePath
            if (existing != null && File(existing).existsNonEmpty()) {
                createRenderer(existing, holder)
            } else {
                adoptSource()
            }
        }

        private fun createRenderer(videoPath: String, holder: SurfaceHolder) {
            try {
                val enableAudio = prefs.getBoolean(KEY_ENABLE_AUDIO, false)
                val loop = prefs.getBoolean(KEY_LOOP, true)

                videoRenderer = VideoRenderer(applicationContext).apply {
                    audioEnabled = enableAudio
                    loopEnabled = loop
                    // Resume key = the adopted SOURCE -> the home engine continues where the chooser's preview engine was.
                    initialize(videoPath, holder, adoptedSourcePath ?: videoPath)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error starting renderer", e)
            }
        }

        // A new source -> adopt a private copy of it FIRST. The old video keeps playing meanwhile, and a
        // failed copy leaves it playing for good; [onAdopted] swaps the player once the copy lands.
        private fun onSourceVideoChanged() {
            if (configuredSourcePath() == adoptedSourcePath) return
            adoptSource()
        }

        // Copies the configured source into this engine's private copy on [ioExecutor] and hands the
        // result back to the thread that asked. The copy is established once and reused across surface
        // recreations, and kept IN MEMORY, never in prefs -> sibling home/lock engines must not share or
        // delete each other's copy.
        private fun adoptSource() {
            val source = configuredSourcePath()
            if (source.isNullOrBlank()) {
                Log.e(TAG, "No source video to adopt")
                return
            }
            if (source == adoptingSource) return // already copying it; that copy starts the renderer
            val generation = ++adoptGeneration
            val replyTo = Handler(Looper.myLooper() ?: Looper.getMainLooper())
            val queued = runIo {
                val copy = copyToEnginePrivate(File(source))
                if (copy != null) sweepOrphanPrivateCopies(keep = copy.absolutePath)
                replyTo.post { onAdopted(generation, source, copy) }
            }
            adoptingSource = if (queued) source else null
        }

        private fun onAdopted(generation: Int, source: String, copy: File?) {
            if (destroyed || generation != adoptGeneration) {
                // Superseded or torn down while copying -> this copy belongs to nobody.
                if (copy != null) runIo { copy.delete() }
                return
            }
            adoptingSource = null
            if (copy == null) return // keep playing what we have

            val stalePrivate = enginePrivatePath
            enginePrivatePath = copy.absolutePath
            adoptedSourcePath = source
            // Unlinking the old copy mid-decode is safe because the decoder's fd stays valid -> overwriting it would not be.
            if (stalePrivate != null && stalePrivate != copy.absolutePath) {
                runIo { File(stalePrivate).delete() }
            }
            showAdopted(copy.absolutePath)
        }

        private fun showAdopted(path: String) {
            if (!surfaceSized) return // the next sized onSurfaceChanged picks it up
            val renderer = videoRenderer
            if (renderer != null) {
                renderer.swapVideo(path, surfaceHolder, adoptedSourcePath ?: path)
            } else {
                // The first start, or the first apply landing on a blank-surface engine.
                createRenderer(path, surfaceHolder)
            }
        }

        // [ioExecutor] only.
        private fun copyToEnginePrivate(source: File): File? {
            if (!source.existsNonEmpty()) {
                Log.e(TAG, "No source video to adopt (path=${source.path})")
                return null
            }
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

        // [ioExecutor] only.
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
                // A zero-sized pass is geometry that has not settled -> keep waiting, decode nothing.
                if (width <= 0 || height <= 0) return
                surfaceSized = true
                val renderer = videoRenderer
                if (renderer == null) startRenderer(holder) else renderer.onSurfaceChanged(holder)
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
            surfaceSized = false
            try {
                videoRenderer?.onSurfaceDestroyed()
            } catch (e: Exception) {
                Log.e(TAG, "Error in onSurfaceDestroyed", e)
            }
            super.onSurfaceDestroyed(holder)
        }

        override fun onDestroy() {
            destroyed = true
            adoptGeneration++
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
                enginePrivatePath?.let { path -> runIo { File(path).delete() } }
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
