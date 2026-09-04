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

// Bridges the Engine's [SurfaceHolder] to Media3 ExoPlayer -> every decision below was earned on budget hardware.
// ExoPlayer does NOT free the decoder on pause() -> it holds the MediaCodec for the player's whole lifetime.
// On a SoC with 2-3 concurrent decoders a paused-but-alive wallpaper occupies a slot WHILE INVISIBLE.
// That is exactly when the feed pool and the next apply preview need one -> release on invisible, re-create on visible.
// The cost is a brief re-buffer on return, which is the right trade here.
// The release is debounced by [INVISIBLE_RELEASE_DELAY_MS] -> a shade pull or recents peek pauses and resumes seamlessly.
// Only a sustained absence frees the decoder.
// Every error is caught and never crashes the service -> a crashing wallpaper service drops the user to the default.
// Loop is REPEAT_MODE_ALL for seamlessness; audio is volume 0 or 1 and is never removed from the pipeline.
// Scaling is SCALE_TO_FIT_WITH_CROPPING -> sources are ~9:16 and every modern screen is taller.
// The default SCALE_TO_FIT filled the surface NON-uniformly -> on a 1080x2392 panel that is a ~24% vertical stretch.
// It showed on the applied wallpaper AND in the OS chooser preview, which previews this very service.
// SCALE_TO_FIT_WITH_CROPPING scales uniformly and centre-crops -> aspect-true and full-bleed, like the feed's BoxFit.cover.
// The native window applies it at composite time from whatever surface the engine hands over.
// So it needs no display metrics, holds on every device and aspect, and re-derives itself on rotation or resize.
// ONE mode, but it is set MANY times: the mode lives on the MediaCodec, not on the player, and the platform
// documents it as reset to the default on an output-buffer change, requiring a re-set before the next buffer
// is rendered. Media3 only re-applies it on an output FORMAT change, so a codec that re-allocates its output
// buffers renders stretched until the next format change -- for a looping wallpaper, a whole loop.
// A codec is (re)created on every visibility resume here, so that window reopens on EVERY home<->app switch.
// [assertScalingMode] is therefore called wherever the codec could have lost it: after the surface is
// (re)attached, on visibility resume, and as soon as the renderer reports a size or a first frame.
// Do not try to pass the mode through the configure MediaFormat (`android._video-scaling`): MediaCodec overwrites
// it with its own default at configure, so the codec still logs `= 1` and the key is dead weight.
//
// A rebuilt codec means a RESTARTED clip. Releasing the decoder while invisible is right for the budget,
// but re-creating the player at position 0 replays the clip's opening on every return to the home screen.
// A generated clip often opens on a wide shot and zooms in -> the user reads that replay as the wallpaper
// "stretching in, then out" every time (and once on first apply, when the home engine starts at 0 while the
// chooser's preview engine was mid-clip). [resumePositions] keeps the last position per source path,
// process-wide, so a rebuilt player and a brand-new engine both continue from where the clip was.
@UnstableApi
class VideoRenderer(private val context: Context) {

    companion object {
        private const val TAG = "VideoRenderer"

        /** Grace period before a now-invisible wallpaper releases its decoder. */
        private const val INVISIBLE_RELEASE_DELAY_MS = 500L

        /** The ONE scaling mode. Never derived from display metrics, never a second mode. */
        private const val SCALING_MODE = C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING

        /** Last playback position per source path, shared by every engine in this process -> see the header. */
        private val resumePositions = ConcurrentHashMap<String, Long>()

        /** Renderers currently PLAYING a source -> a new engine can take the live position when none was stored yet. */
        private val liveByKey = ConcurrentHashMap<String, VideoRenderer>()

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
            player?.volume = if (value) 1.0f else 0.0f
        }

    @Volatile
    var loopEnabled: Boolean = true
        set(value) {
            field = value
            player?.repeatMode =
                if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
        }

    fun initialize(videoPath: String, surfaceHolder: SurfaceHolder, resumeKey: String = videoPath) {
        logd("Initializing with video: $videoPath")
        mainHandler.removeCallbacks(releaseOnIdle)

        currentVideoPath = videoPath
        this.resumeKey = resumeKey
        currentSurfaceHolder = surfaceHolder

        // Release any existing player but keep the retained path and holder above.
        releasePlayerInstance()

        try {
            // On first apply the chooser's preview engine is usually still alive when the home engine
            // starts -> nothing was stored yet, so read the preview's live position instead of starting
            // at 0 and replaying the clip's opening shot.
            val startMs = resumePositions[resumeKey]
                ?: liveByKey[resumeKey]?.takeIf { it !== this }?.player?.currentPosition?.takeIf { it > 0L }
                ?: 0L
            player = ExoPlayer.Builder(context).build().apply {
                setVideoSurfaceHolder(surfaceHolder)
                // Aspect-true full-bleed -> set on the PLAYER, not per item, so swapVideo keeps it when it reuses this instance.
                // A re-created player passes through here again. It is re-asserted later too — see [assertScalingMode].
                setVideoScalingMode(SCALING_MODE)
                volume = if (audioEnabled) 1.0f else 0.0f
                repeatMode = if (loopEnabled) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
                playWhenReady = true
                addListener(createPlayerListener())
                // Continue where this clip was, not from its opening shot -> see the header.
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

    // Swaps the playing video in place, same engine and same player.
    // It is needed because Android ignores a re-Set of the same component and never recreates the engine.
    // If the player is already released, past the invisible grace period, only the retained path is updated.
    // The next visibility gain then re-initializes with the new video through that path.
    // Deliberately does NOT force play() -> playWhenReady is preserved, so an invisible-paused player stays paused.
    // A pending [releaseOnIdle] still frees the decoder.
    fun swapVideo(videoPath: String, surfaceHolder: SurfaceHolder, resumeKey: String = videoPath) {
        logd("Swapping video in place: $videoPath")
        this.resumeKey?.let { resumePositions.remove(it) }
        resumePositions.remove(resumeKey)
        this.resumeKey = resumeKey
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

    fun onSurfaceChanged(surfaceHolder: SurfaceHolder) {
        try {
            // Retain the LIVE holder even while the decoder is released -> the next visibility gain
            // re-initializes onto this surface and never onto a destroyed one.
            currentSurfaceHolder = surfaceHolder
            val activePlayer = player
            if (activePlayer != null) {
                activePlayer.setVideoSurfaceHolder(surfaceHolder)
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

    fun onSurfaceDestroyed() {
        logd("Surface destroyed")
        mainHandler.removeCallbacks(releaseOnIdle)
        currentSurfaceHolder = null
        releasePlayerInstance()
    }

    fun onVisibilityChanged(visible: Boolean) {
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
                // Remember where the clip was so the rebuilt player, or the next engine, resumes there.
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

    fun release() {
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
