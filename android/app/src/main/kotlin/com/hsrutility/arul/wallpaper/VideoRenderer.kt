package com.hsrutility.arul.wallpaper

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.hsrutility.arul.BuildConfig
import java.io.File

/**
 * Manages ExoPlayer lifecycle for the live (video) wallpaper, bridging the
 * Engine's [SurfaceHolder] to Media3 ExoPlayer.
 *
 * Adopted verbatim (logic) from the vendored flutter_wallpaper_plus VideoRenderer
 * — every decision below was earned on real budget hardware:
 *
 * 1. The player is created in [initialize] and FULLY released in
 *    [releasePlayerInstance]. On visibility loss we release the player (and its
 *    hardware MediaCodec) and re-create it on visibility gain — ExoPlayer does
 *    NOT free the decoder on pause(); it holds the MediaCodec for the player's
 *    lifetime. On budget SoCs with 2–3 concurrent decoders, a paused-but-alive
 *    wallpaper would permanently occupy a slot WHILE INVISIBLE — exactly when the
 *    app's feed pool and the next apply preview need one. Releasing on invisible
 *    returns the slot. Cost: a brief re-buffer on return (the right trade here).
 *
 * 2. The release is debounced ([INVISIBLE_RELEASE_DELAY_MS]) so transient flaps
 *    (notification shade, recents peek) just pause and resume seamlessly; only a
 *    sustained absence frees the decoder.
 *
 * 3. Errors are caught and never crash the service — a crashing wallpaper service
 *    forces the user back to the default wallpaper (very bad UX).
 *
 * 4. Loop = REPEAT_MODE_ALL (seamless). Audio = volume 0/1 (muted by default for
 *    a wallpaper; never removed from the pipeline).
 *
 * 5. Scaling = SCALE_TO_FIT_WITH_CROPPING, set once per player. Our sources are
 *    ~9:16 (1024x1824) and every modern screen is taller (9:19.5-9:20+), so the
 *    default SCALE_TO_FIT filled the engine surface NON-uniformly: on a 1080x2392
 *    panel that is x1.055 across and x1.311 down, a ~24% vertical stretch on the
 *    applied wallpaper AND in the OS chooser preview (which previews this very
 *    service). SCALE_TO_FIT_WITH_CROPPING scales uniformly and centre-crops the
 *    overflow instead - aspect-true, full-bleed, matching the in-app feed's
 *    BoxFit.cover. It is applied by the native window at composite time from
 *    whatever surface the engine hands us, so it needs no display metrics, holds
 *    on every device and aspect, and re-derives itself on rotation/resize.
 */
@UnstableApi
class VideoRenderer(private val context: Context) {

    companion object {
        private const val TAG = "VideoRenderer"

        /** Grace period before a now-invisible wallpaper releases its decoder. */
        private const val INVISIBLE_RELEASE_DELAY_MS = 500L

        /** Debug-only log; the BuildConfig.DEBUG gate strips it from release. */
        private fun logd(msg: String) {
            if (BuildConfig.DEBUG) Log.d(TAG, msg)
        }
    }

    private var player: ExoPlayer? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private val releaseOnIdle = Runnable {
        logd("Invisible past grace period — releasing decoder")
        releasePlayerInstance()
    }

    /** Retained so the player can be re-created after a visibility-driven release. */
    private var currentVideoPath: String? = null

    /** Retained so the surface can be re-attached on re-creation; null once destroyed. */
    private var currentSurfaceHolder: SurfaceHolder? = null

    @Volatile
    var audioEnabled: Boolean = false
        set(value) {
            field = value
            player?.volume = if (value) 1.0f else 0.0f
        }

    @Volatile
    var loopEnabled: Boolean = true
        set(value) {
            field = value
            player?.repeatMode =
                if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
        }

    fun initialize(videoPath: String, surfaceHolder: SurfaceHolder) {
        logd("Initializing with video: $videoPath")
        mainHandler.removeCallbacks(releaseOnIdle)

        currentVideoPath = videoPath
        currentSurfaceHolder = surfaceHolder

        // Release any existing player but keep the retained path/holder above.
        releasePlayerInstance()

        try {
            player = ExoPlayer.Builder(context).build().apply {
                setVideoSurfaceHolder(surfaceHolder)
                // Aspect-true full-bleed - see point 5 in the class doc. Set on the
                // player (not per-item), so swapVideo, which reuses this instance,
                // keeps it; a re-created player passes through here again.
                setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING)
                volume = if (audioEnabled) 1.0f else 0.0f
                repeatMode = if (loopEnabled) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
                playWhenReady = true
                addListener(createPlayerListener())
                setMediaItem(MediaItem.fromUri("file://$videoPath"))
                prepare()
            }
            logd("Player initialized successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize player", e)
            release()
        }
    }

    /**
     * Swaps the playing video in place (same engine, same player) — used when a
     * new live wallpaper is applied while THIS service is already the active
     * system wallpaper, because Android ignores a re-Set of the same component
     * ("Changing to the same component, ignoring") and never recreates the engine.
     *
     * If the player is currently released (invisible past the grace period), only
     * the retained path is updated; the next visibility gain re-initializes with
     * the new video via the existing path. Deliberately does NOT force play():
     * playWhenReady is preserved, so an invisible-paused player stays paused and
     * a pending [releaseOnIdle] still frees the decoder.
     */
    fun swapVideo(videoPath: String, surfaceHolder: SurfaceHolder) {
        logd("Swapping video in place: $videoPath")
        currentVideoPath = videoPath
        currentSurfaceHolder = surfaceHolder

        val activePlayer = player ?: return
        try {
            activePlayer.setMediaItem(MediaItem.fromUri("file://$videoPath"))
            activePlayer.prepare()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to swap video", e)
            // Keep the retained path/holder so the next visibility gain re-inits
            // cleanly with the new video instead of looping a broken player.
            releasePlayerInstance()
        }
    }

    fun onSurfaceChanged(surfaceHolder: SurfaceHolder) {
        try {
            player?.setVideoSurfaceHolder(surfaceHolder)
        } catch (e: Exception) {
            Log.e(TAG, "Error on surface change", e)
        }
    }

    fun onSurfaceDestroyed() {
        logd("Surface destroyed")
        mainHandler.removeCallbacks(releaseOnIdle)
        currentSurfaceHolder = null
        releasePlayerInstance()
    }

    fun onVisibilityChanged(visible: Boolean) {
        logd("Visibility changed: $visible")
        try {
            if (visible) {
                mainHandler.removeCallbacks(releaseOnIdle)
                val activePlayer = player
                if (activePlayer != null) {
                    activePlayer.play()
                } else {
                    val path = currentVideoPath
                    val holder = currentSurfaceHolder
                    if (path != null && holder != null) {
                        initialize(path, holder)
                    } else {
                        logd("Visible but cannot re-init; waiting for surface")
                    }
                }
            } else {
                player?.pause()
                mainHandler.removeCallbacks(releaseOnIdle)
                mainHandler.postDelayed(releaseOnIdle, INVISIBLE_RELEASE_DELAY_MS)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error on visibility change", e)
        }
    }

    private fun releasePlayerInstance() {
        try {
            player?.let { p ->
                p.stop()
                p.clearVideoSurface()
                p.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing player (non-critical)", e)
        } finally {
            player = null
        }
    }

    fun release() {
        mainHandler.removeCallbacks(releaseOnIdle)
        releasePlayerInstance()
        currentVideoPath = null
        currentSurfaceHolder = null
    }

    private fun createPlayerListener(): Player.Listener = object : Player.Listener {
        override fun onPlayerError(error: PlaybackException) {
            Log.e(TAG, "Playback error: ${error.errorCodeName} — ${error.message}", error)

            // If the source file is gone, re-prepare() would loop forever — bail.
            val path = currentVideoPath
            if (path != null && !File(path).exists()) {
                Log.e(TAG, "Source file missing; not retrying: $path")
                return
            }
            try {
                player?.let { p ->
                    p.seekTo(0)
                    p.prepare()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Recovery failed", e)
            }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED && !loopEnabled) {
                try {
                    player?.seekTo(0)
                    player?.pause()
                } catch (e: Exception) {
                    Log.e(TAG, "Error handling video end", e)
                }
            }
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            logd("Video size: ${videoSize.width}x${videoSize.height}")
        }
    }
}
