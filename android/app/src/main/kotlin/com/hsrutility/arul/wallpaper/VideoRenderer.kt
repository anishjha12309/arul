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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// ExoPlayer does NOT free the decoder on pause() -> it holds the MediaCodec for the player's whole lifetime.
// The release is debounced by [INVISIBLE_RELEASE_DELAY_MS] -> a shade pull or recents peek pauses and resumes seamlessly.
// Only a sustained absence frees the decoder.
// THREADING. A Media3 player may only be touched from the one thread it was built on, and the
// framework's own teardown path calls straight into it: WallpaperService.Engine.detach() ->
// reportSurfaceDestroyed() -> ExoPlayer's SurfaceHolder.Callback. Left to itself Media3 adopts the
// looper of whoever called the builder, and some OEM wallpaper services (every crash in the 3-10 Sep
// window was a Vivo) start an engine off the main thread while detach() arrives on it. The player
// then rejects stop()/release() -- swallowed here as non-critical -- so it stays registered on the
// holder, and the framework's next callback kills the PROCESS, dropping the user to the default
// wallpaper. So the looper is PINNED to main and every entry point goes through [onMain]. On a
// device whose engine already runs on main this changes nothing: that is the looper Media3 picked.
@UnstableApi
class VideoRenderer(private val context: Context) {

    companion object {
        private const val TAG = "VideoRenderer"

        private const val INVISIBLE_RELEASE_DELAY_MS = 500L

        private const val SURFACE_RELEASE_WAIT_MS = 1_000L

        /** The ONE scaling mode. Never derived from display metrics, never a second mode. */
        private const val SCALING_MODE = C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING

        private val resumePositions = ConcurrentHashMap<String, Long>()

        /** Renderers currently PLAYING a source -> a new engine can take the live position when none was stored yet. */
        private val liveByKey = ConcurrentHashMap<String, VideoRenderer>()

        private fun logd(msg: String) {
            if (BuildConfig.DEBUG) Log.d(TAG, msg)
        }
    }

    private var player: ExoPlayer? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Runs [block] on the ONE thread this renderer's player may be touched from -> see the header.
     *  INLINE when already there, so a teardown that has to finish before the framework's own
     *  `detach()` still does; posted otherwise, which keeps call order. */
    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post { block() }
    }

    /** [onMain] that an off-main caller WAITS on, bounded, for the one teardown that must finish
     *  before the framework's own next step -> a Surface it is about to free. Inline on main. */
    private fun onMainAwait(timeoutMs: Long, block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
            return
        }
        val done = CountDownLatch(1)
        mainHandler.post {
            try {
                block()
            } finally {
                done.countDown()
            }
        }
        try {
            if (!done.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                Log.w(TAG, "Surface release still pending on main after ${timeoutMs}ms")
            }
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private val releaseOnIdle = Runnable {
        logd("Invisible past grace period — releasing decoder")
        releasePlayerInstance()
    }

    /** Retained so the player can be re-created after a visibility-driven release. */
    private var currentVideoPath: String? = null

    /** Key into [resumePositions]: the SOURCE the engine adopted, shared by every engine playing that clip. */
    private var resumeKey: String? = null

    /** Retained so the surface can be re-attached on re-creation; null once destroyed. */
    private var currentSurfaceHolder: SurfaceHolder? = null

    /** Last visibility the engine reported -> tells a surface swap on screen from one behind an app. */
    private var visible = false

    @Volatile
    var audioEnabled: Boolean = false
        set(value) {
            field = value
            onMain { player?.volume = if (value) 1.0f else 0.0f }
        }

    @Volatile
    var loopEnabled: Boolean = true
        set(value) {
            field = value
            onMain {
                player?.repeatMode =
                    if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
            }
        }

    fun initialize(videoPath: String, surfaceHolder: SurfaceHolder, resumeKey: String = videoPath) = onMain {
        logd("Initializing with video: $videoPath")
        mainHandler.removeCallbacks(releaseOnIdle)

        currentVideoPath = videoPath
        this.resumeKey = resumeKey
        currentSurfaceHolder = surfaceHolder

        releasePlayerInstance()

        try {
            // On first apply the chooser's preview engine is usually still alive when the home engine
            // starts -> nothing was stored yet, so read the preview's live position instead of starting
            // at 0 and replaying the clip's opening shot.
            val startMs = resumePositions[resumeKey]
                ?: liveByKey[resumeKey]?.takeIf { it !== this }?.player?.currentPosition?.takeIf { it > 0L }
                ?: 0L
            player = ExoPlayer.Builder(context)
                // The whole point of [onMain] -> read the threading note in the header.
                .setLooper(Looper.getMainLooper())
                .build()
                .apply {
                setVideoSurface(surfaceHolder.surface)
                setVideoScalingMode(SCALING_MODE)
                volume = if (audioEnabled) 1.0f else 0.0f
                repeatMode = if (loopEnabled) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
                playWhenReady = true
                addListener(createPlayerListener())
                setMediaItem(MediaItem.fromUri("file://$videoPath"), startMs)
                prepare()
            }
            liveByKey[resumeKey] = this
            logd("Player initialized successfully at ${startMs}ms")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize player", e)
            release()
        }
    }

    // If the player is already released, past the invisible grace period, only the retained path is updated.
    // The next visibility gain then re-initializes with the new video through that path.
    // Deliberately does NOT force play() -> playWhenReady is preserved, so an invisible-paused player stays paused.
    fun swapVideo(videoPath: String, surfaceHolder: SurfaceHolder, resumeKey: String = videoPath) = onMain {
        logd("Swapping video in place: $videoPath")
        this.resumeKey?.let { resumePositions.remove(it) }
        resumePositions.remove(resumeKey)
        this.resumeKey = resumeKey
        currentVideoPath = videoPath
        currentSurfaceHolder = surfaceHolder

        val activePlayer = player ?: return@onMain
        try {
            activePlayer.setMediaItem(MediaItem.fromUri("file://$videoPath"))
            activePlayer.prepare()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to swap video", e)
            // Keep the retained path and holder -> the next visibility gain re-inits cleanly instead of looping a broken player.
            releasePlayerInstance()
        }
    }

    // Re-states the ONE scaling mode on the live codec. Cheap, idempotent, and safe to call often:
    // it is a player message that ends at MediaCodec.setVideoScalingMode, which is where the mode
    // actually lives and where the platform can reset it to the stretching default underneath us.
    private fun assertScalingMode() {
        try {
            player?.setVideoScalingMode(SCALING_MODE)
        } catch (e: Exception) {
            Log.w(TAG, "Could not re-assert scaling mode (non-critical)", e)
        }
    }

    fun onSurfaceChanged(surfaceHolder: SurfaceHolder) = onMain {
        try {
            // Retain the LIVE holder even while the decoder is released -> the next visibility gain
            // re-initializes onto this surface and never onto a destroyed one.
            currentSurfaceHolder = surfaceHolder
            val activePlayer = player
            if (activePlayer != null) {
                activePlayer.setVideoSurface(surfaceHolder.surface)
                // Re-attaching an output surface drops the codec's scaling mode -> restate it here,
                // not only where the player is built.
                assertScalingMode()
            } else if (visible) {
                // The surface was recreated while the wallpaper is ON SCREEN — a rotation or display
                // change — so the decoder went with it and no visibility event will come to rebuild it.
                // While invisible this stays null on purpose: the release freed a decoder slot.
                currentVideoPath?.let { initialize(it, surfaceHolder, resumeKey ?: it) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error on surface change", e)
        }
    }

    // Awaited, not merely posted: the framework frees the Surface the moment this returns, and the
    // player has to have let go of it first (clearVideoSurface inside the release).
    fun onSurfaceDestroyed() = onMainAwait(SURFACE_RELEASE_WAIT_MS) {
        logd("Surface destroyed")
        mainHandler.removeCallbacks(releaseOnIdle)
        currentSurfaceHolder = null
        releasePlayerInstance()
    }

    fun onVisibilityChanged(visible: Boolean) = onMain {
        logd("Visibility changed: $visible")
        this.visible = visible
        try {
            if (visible) {
                mainHandler.removeCallbacks(releaseOnIdle)
                val activePlayer = player
                if (activePlayer != null) {
                    // A kept codec that was only paused can still have been reset underneath us.
                    assertScalingMode()
                    activePlayer.play()
                } else {
                    val path = currentVideoPath
                    val holder = currentSurfaceHolder
                    if (path != null && holder != null) {
                        initialize(path, holder, resumeKey ?: path)
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
                resumeKey?.let { key ->
                    val pos = p.currentPosition
                    if (pos > 0L) resumePositions[key] = pos
                    liveByKey.remove(key, this)
                }
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

    fun release() = onMain {
        mainHandler.removeCallbacks(releaseOnIdle)
        releasePlayerInstance()
        currentVideoPath = null
        currentSurfaceHolder = null
        visible = false
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

        // The two earliest points at which a codec exists for a fresh decode: the output format is
        // known, and the first buffer has reached the surface. Restating the mode at both is what
        // keeps a rebuilt codec — one per visibility resume — from showing stretched frames for a
        // whole loop, until Media3's next output-format change would have restored it by itself.
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            logd("Video size: ${videoSize.width}x${videoSize.height}")
            assertScalingMode()
        }

        override fun onRenderedFirstFrame() {
            assertScalingMode()
        }
    }
}
