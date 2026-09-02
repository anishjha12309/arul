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

// Bridges the Engine's [SurfaceHolder] to Media3 ExoPlayer -> every decision below was earned on budget hardware.
// ExoPlayer does NOT free the decoder on pause() -> it holds the MediaCodec for the player's whole lifetime.
// On a SoC with 2-3 concurrent decoders a paused-but-alive wallpaper occupies a slot WHILE INVISIBLE.
// That is exactly when the feed pool and the next apply preview need one -> release on invisible, re-create on visible.
// The cost is a brief re-buffer on return, which is the right trade here.
// The release is debounced by [INVISIBLE_RELEASE_DELAY_MS] -> a shade pull or recents peek pauses and resumes seamlessly.
// Only a sustained absence frees the decoder.
// Every error is caught and never crashes the service -> a crashing wallpaper service drops the user to the default.
// Loop is REPEAT_MODE_ALL for seamlessness; audio is volume 0 or 1 and is never removed from the pipeline.
// Scaling is SCALE_TO_FIT_WITH_CROPPING, set once per player -> sources are ~9:16 and every modern screen is taller.
// The default SCALE_TO_FIT filled the surface NON-uniformly -> on a 1080x2392 panel that is a ~24% vertical stretch.
// It showed on the applied wallpaper AND in the OS chooser preview, which previews this very service.
// SCALE_TO_FIT_WITH_CROPPING scales uniformly and centre-crops -> aspect-true and full-bleed, like the feed's BoxFit.cover.
// The native window applies it at composite time from whatever surface the engine hands over.
// So it needs no display metrics, holds on every device and aspect, and re-derives itself on rotation or resize.
@UnstableApi
class VideoRenderer(private val context: Context) {

    companion object {
        private const val TAG = "VideoRenderer"

        /** Grace period before a now-invisible wallpaper releases its decoder. */
        private const val INVISIBLE_RELEASE_DELAY_MS = 500L

        /** Debug-only log -> the BuildConfig.DEBUG gate strips it from a release build. */
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

        // Release any existing player but keep the retained path and holder above.
        releasePlayerInstance()

        try {
            player = ExoPlayer.Builder(context).build().apply {
                setVideoSurfaceHolder(surfaceHolder)
                // Aspect-true full-bleed -> set on the PLAYER, not per item, so swapVideo keeps it when it reuses this instance.
                // A re-created player passes through here again.
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

    // Swaps the playing video in place, same engine and same player.
    // It is needed because Android ignores a re-Set of the same component and never recreates the engine.
    // If the player is already released, past the invisible grace period, only the retained path is updated.
    // The next visibility gain then re-initializes with the new video through that path.
    // Deliberately does NOT force play() -> playWhenReady is preserved, so an invisible-paused player stays paused.
    // A pending [releaseOnIdle] still frees the decoder.
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
            // Keep the retained path and holder -> the next visibility gain re-inits cleanly instead of looping a broken player.
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

            // A missing source file would make re-prepare() loop forever -> bail instead.
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
