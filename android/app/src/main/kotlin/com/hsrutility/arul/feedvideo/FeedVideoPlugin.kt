package com.hsrutility.arul.feedvideo

import android.content.Context
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

// An unknown or stale playerId is a success no-op -> a call arriving just after dispose() must never throw.
// The first painted frame is reported natively via onRenderedFirstFrame -> no width + surface-rect settle dance.
// That callback can fire for a PREVIOUS media around a swap -> every open() bumps an openId echoed on the event.
class FeedVideoPlugin(
    private val context: Context,
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.hsrutility.arul/feed_video"
        const val EVENT_CHANNEL = "com.hsrutility.arul/feed_video_events"
        private const val TAG = "FeedVideoPlugin"

        // A looping short preview never needs a deep buffer -> keep the demuxer budget small.
        // These are the LOCAL-playback figures: every feed open is a file:// path (the Dart side
        // downloads first), and DefaultLoadControl.LOCAL_PLAYBACK_SCHEMES covers file/asset.
        private const val MIN_BUFFER_MS = 2_000
        private const val MAX_BUFFER_MS = 4_000
        private const val BUFFER_FOR_PLAYBACK_MS = 250
        private const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 1_000

        // Buffer the whole clip before the first frame instead: the poster covers the wait, and the
        // lap that follows plays from memory. Split from the local figures via Media3's
        // setBufferDurationsMsForStreaming, so an open from a file is unaffected.
        private const val STREAM_MIN_BUFFER_MS = 12_000
        private const val STREAM_MAX_BUFFER_MS = 20_000
        private const val STREAM_BUFFER_FOR_PLAYBACK_MS = 10_000
        private const val STREAM_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 10_000
    }

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also {
        it.setMethodCallHandler(this)
    }
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL).also {
        it.setStreamHandler(this)
    }

    private var eventSink: EventChannel.EventSink? = null

    private val players = HashMap<Int, PooledSurfacePlayer>()
    private var nextPlayerId = 1

    // ONE focus request for every audible player. Per-player Media3 focus made each new clip take
    // focus from the pool's previous player as a PERMANENT loss, which latched the reel paused.
    // Only another app's loss reaches Dart now; a refused request (Android 15+, not top app) never plays.
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusHeld = false
    private val focusListener = AudioManager.OnAudioFocusChangeListener { onFocusChange(it) }
    private val focusRequest: AudioFocusRequest? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, Handler(Looper.getMainLooper()))
                .build()
        } else {
            null
        }

    private fun requestFocus(): Boolean {
        if (focusHeld) return true
        val granted = if (focusRequest != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioManager.requestAudioFocus(focusRequest)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        focusHeld = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!focusHeld) Log.w(TAG, "audio focus refused")
        return focusHeld
    }

    private fun abandonFocusIfIdle() {
        if (!focusHeld || players.values.any { it.wantsAudio() }) return
        if (focusRequest != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioManager.abandonAudioFocusRequest(focusRequest)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
        focusHeld = false
    }

    // A call or another app took the speaker -> pause and let Dart hold the clip until a tap.
    // A duck is left to the system, which lowers the volume itself on Android 8+.
    private fun onFocusChange(change: Int) {
        if (change != AudioManager.AUDIOFOCUS_LOSS && change != AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) return
        focusHeld = false
        for ((id, p) in players) {
            if (!p.wantsAudio()) continue
            p.pause()
            emit(id, "focusLost", mapOf("openId" to p.currentOpenId()))
        }
    }


    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        // Dart keeps ONE process-global subscription on this channel -> native gets exactly one live sink.
        // Flutter always delivers onCancel for the previous listener before onListen for its replacement.
        // So a plain assign is correct -> `events` is always the newest live sink.
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        // onCancel(old) precedes onListen(new) on the single main thread -> a cancel here always means the current sink.
        eventSink = null
    }


    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> result.success(create(call.argument<Boolean>("audio") ?: false))
                "open" -> {
                    val id = call.argument<Int>("playerId") ?: return result.success(null)
                    val url = call.argument<String>("url") ?: return result.success(null)
                    val playWhenReady = call.argument<Boolean>("playWhenReady") ?: false
                    val looping = call.argument<Boolean>("looping") ?: true
                    result.success(open(id, url, playWhenReady, looping))
                }
                "play" -> {
                    val id = call.argument<Int>("playerId")
                    if (id != null) players[id]?.play()
                    result.success(null)
                }
                "pause" -> {
                    val id = call.argument<Int>("playerId")
                    if (id != null) players[id]?.pause()
                    result.success(null)
                }
                "stop" -> {
                    val id = call.argument<Int>("playerId")
                    if (id != null) players[id]?.stop()
                    result.success(null)
                }
                "warmConnection" -> {
                    val url = call.argument<String>("url")
                    if (url != null) warmConnection(url)
                    result.success(null)
                }
                "setVolume" -> {
                    val id = call.argument<Int>("playerId")
                    val volume = call.argument<Double>("volume")
                    if (id != null && volume != null) players[id]?.setVolume(volume.toFloat())
                    result.success(null)
                }
                "paintedOpenId" -> {
                    val id = call.argument<Int>("playerId")
                    result.success(if (id != null) players[id]?.paintedOpenId() ?: -1 else -1)
                }
                "dispose" -> {
                    val id = call.argument<Int>("playerId")
                    if (id != null) disposePlayer(id)
                    result.success(null)
                }
                "disposeAll" -> {
                    disposeAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Never surface a native crash to Dart mid-scroll -> log it and no-op.
            Log.e(TAG, "onMethodCall(${call.method}) failed", e)
            result.success(null)
        }
    }


    private fun create(audio: Boolean): Map<String, Any> {
        logDecoderCapsOnce()
        val playerId = nextPlayerId++
        if (audio) Log.i(TAG, "audible create: player $playerId")
        val pooled = PooledSurfacePlayer(playerId, audio)
        players[playerId] = pooled
        return mapOf("playerId" to playerId, "textureId" to pooled.textureId)
    }

    // One-shot logcat diagnostic -> what the SoC CLAIMS its concurrent decoder ceiling is for the feed's codecs.
    // Diagnostic ONLY -> the number lies in both directions, so Dart adapts on real decoder errors instead.
    private var loggedDecoderCaps = false
    private fun logDecoderCapsOnce() {
        if (loggedDecoderCaps) return
        loggedDecoderCaps = true
        Thread {
            try {
                for (mime in listOf("video/avc", "video/hevc")) {
                    val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull {
                        !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, ignoreCase = true) }
                    } ?: continue
                    val max = info.getCapabilitiesForType(mime).maxSupportedInstances
                    Log.i(TAG, "decoder caps: $mime via ${info.name}, maxSupportedInstances=$max")
                }
            } catch (e: Exception) {
                Log.w(TAG, "decoder caps query failed (diagnostic only)", e)
            }
        }.start()
    }

    private fun open(
        playerId: Int,
        url: String,
        playWhenReady: Boolean,
        looping: Boolean,
    ): Long {
        val pooled = players[playerId] ?: return -1
        return pooled.open(url, playWhenReady, looping)
    }

    // ExoPlayer's DefaultHttpDataSource is built on HttpURLConnection, whose keep-alive pool is per-JVM.
    // So a request issued here from the same stack is the one the player reuses.
    // It must NOT be a Dart-side fetch -> dart:io has its own pool and would warm nothing the player can see.
    private fun warmConnection(url: String) {
        Thread {
            try {
                val c = URL(url).openConnection() as HttpURLConnection
                c.setRequestProperty("Range", "bytes=0-1")
                c.connectTimeout = 5_000
                c.readTimeout = 5_000
                c.inputStream.use { it.read() }
                Log.i(TAG, "warmed CDN connection (${c.responseCode})")
            } catch (e: Exception) {
                Log.w(TAG, "connection warm failed", e)
            }
        }.start()
    }

    private fun disposePlayer(playerId: Int) {
        players.remove(playerId)?.release()
        abandonFocusIfIdle()
    }

    private fun disposeAll() {
        val all = players.values.toList()
        players.clear()
        for (p in all) p.release()
        abandonFocusIfIdle()
    }

    fun dispose() {
        disposeAll()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    private fun emit(playerId: Int, event: String, extra: Map<String, Any>? = null) {
        val sink = eventSink ?: return
        val payload = HashMap<String, Any>()
        payload["playerId"] = playerId
        payload["event"] = event
        if (extra != null) payload.putAll(extra)
        sink.success(payload)
    }


    // It implements SurfaceProducer.Callback so a recycled surface is re-attached in [onSurfaceAvailable].
    // That is what makes the pool Impeller-compatible and lets it survive backgrounding without recreating players.
    private inner class PooledSurfacePlayer(
        private val playerId: Int,
        private val withAudio: Boolean = false,
    ) : TextureRegistry.SurfaceProducer.Callback {

        private val producer: TextureRegistry.SurfaceProducer =
            textureRegistry.createSurfaceProducer()
        val textureId: Long = producer.id()

        private var openId = 0

        // The [openId] of the most recent frame actually rendered to the surface.
        // Dart queries it via `paintedOpenId` -> its reveal timeout fires ONLY when the native event was lost.
        // Never onto a reused player that has not yet painted the current clip, which still shows the previous one.
        private var lastPaintedOpenId = 0
        fun paintedOpenId(): Int = lastPaintedOpenId

        private val player: ExoPlayer

        init {
            producer.setCallback(this)

            val loadControl = DefaultLoadControl.Builder()
                .setBufferDurationsMsForLocalPlayback(
                    MIN_BUFFER_MS,
                    MAX_BUFFER_MS,
                    BUFFER_FOR_PLAYBACK_MS,
                    BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
                )
                .setBufferDurationsMsForStreaming(
                    STREAM_MIN_BUFFER_MS,
                    STREAM_MAX_BUFFER_MS,
                    STREAM_BUFFER_FOR_PLAYBACK_MS,
                    STREAM_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
                )
                .build()

            // Budget SoCs fail hardware codec init when several players are alive -> concurrent-instance limits.
            // Fall back to a lower-priority, possibly software decoder instead of hard-failing.
            // A paused window neighbour only needs its first frame decoded -> a slower decoder is fine there.
            val renderersFactory = DefaultRenderersFactory(context)
                .setEnableDecoderFallback(true)

            player = ExoPlayer.Builder(context, renderersFactory)
                .setLoadControl(loadControl)
                .setAudioAttributes(
                    if (withAudio) {
                        AudioAttributes.Builder()
                            .setUsage(C.USAGE_MEDIA)
                            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                            .build()
                    } else {
                        AudioAttributes.DEFAULT
                    },
                    /* handleAudioFocus = */ false,
                )
                // Headphones out must not move the sound to the speaker -> Media3 pauses on NOISY.
                .setHandleAudioBecomingNoisy(withAudio)
                .build()
                .apply {
                    volume = if (withAudio) 1f else 0f
                    repeatMode = Player.REPEAT_MODE_OFF
                    setVideoSurface(producer.surface)
                    addListener(playerListener())
                    addAnalyticsListener(decoderListener())
                }
        }

        // When the current audible open started, for the +Nms marks below.
        // Perceived speed is "how long the poster sat there", which is exactly open -> firstFrame.
        // Nothing else in the app measures it, and a release build reports no Dart logs at all.
        private var audibleOpenAt = 0L

        fun open(url: String, playWhenReady: Boolean, looping: Boolean): Long {
            val id = ++openId
            if (withAudio) {
                audibleOpenAt = SystemClock.elapsedRealtime()
                Log.i(TAG, "audible open: $url")
            }
            try {
                player.repeatMode =
                    if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                player.setMediaItem(MediaItem.fromUri(toUri(url)))
                player.playWhenReady = playWhenReady && (!withAudio || requestFocus())
                player.prepare()
            } catch (e: Exception) {
                Log.e(TAG, "open failed for player $playerId", e)
                // Tag with THIS open's id -> Dart drops it if a newer open has since swapped in.
                // Tag with a distinct codeName -> Dart recognises a non-decoder open failure and schedules a re-open.
                emit(
                    playerId,
                    "error",
                    mapOf(
                        "openId" to id,
                        "codeName" to "ERROR_CODE_OPEN_FAILED",
                        "message" to (e.message ?: "open failed"),
                    ),
                )
            }
            return id.toLong()
        }

        fun play() {
            try {
                if (withAudio && !requestFocus()) return
                player.playWhenReady = true
            } catch (e: Exception) {
                Log.w(TAG, "play failed for $playerId", e)
            }
        }

        fun pause() {
            try {
                player.playWhenReady = false
            } catch (e: Exception) {
                Log.w(TAG, "pause failed for $playerId", e)
            }
            abandonFocusIfIdle()
        }

        fun wantsAudio(): Boolean = withAudio && player.playWhenReady

        fun currentOpenId(): Int = openId

        fun setVolume(volume: Float) {
            try {
                player.volume = volume.coerceIn(0f, 1f)
            } catch (e: Exception) {
                Log.w(TAG, "setVolume failed for $playerId", e)
            }
        }

        // Moves the player to STATE_IDLE, which RELEASES its codec while the player and its SurfaceProducer survive.
        // A later [open] re-prepares on the same surface -> no churn.
        // Dart uses it to hand a scarce decoder to a higher-priority index on codec-starved SoCs -> never per scroll.
        fun stop() {
            try {
                player.stop()
                player.playWhenReady = false
            } catch (e: Exception) {
                Log.w(TAG, "stop failed for $playerId", e)
            }
            abandonFocusIfIdle()
        }

        fun release() {
            try {
                player.clearVideoSurface()
                player.release()
            } catch (e: Exception) {
                Log.w(TAG, "release failed for $playerId (non-critical)", e)
            } finally {
                producer.release()
            }
        }


        override fun onSurfaceAvailable() {
            try {
                player.setVideoSurface(producer.surface)
            } catch (e: Exception) {
                Log.w(TAG, "onSurfaceAvailable re-attach failed for $playerId", e)
            }
        }

        override fun onSurfaceCleanup() {
            try {
                player.clearVideoSurface()
            } catch (e: Exception) {
                Log.w(TAG, "onSurfaceCleanup failed for $playerId", e)
            }
        }

        private fun playerListener(): Player.Listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                lastPaintedOpenId = openId
                if (withAudio && audibleOpenAt > 0L) {
                    val ms = SystemClock.elapsedRealtime() - audibleOpenAt
                    Log.i(TAG, "audible first frame: +${ms}ms")
                }
                emit(playerId, "firstFrame", mapOf("openId" to openId))
            }

            // Headphones out: Media3 already paused; Dart latches it so no reconcile restarts the clip.
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (playWhenReady || reason != Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY) return
                emit(playerId, "focusLost", mapOf("openId" to openId))
                abandonFocusIfIdle()
            }

            // STATE_ENDED is only reached by a NON-looping open -> a looping player re-enters BUFFERING/READY instead.
            override fun onPlaybackStateChanged(state: Int) {
                if (withAudio && audibleOpenAt > 0L) {
                    val name = when (state) {
                        Player.STATE_IDLE -> "IDLE"
                        Player.STATE_BUFFERING -> "BUFFERING"
                        Player.STATE_READY -> "READY"
                        else -> "ENDED"
                    }
                    val ms = SystemClock.elapsedRealtime() - audibleOpenAt
                    Log.i(TAG, "audible state=$name +${ms}ms")
                }
                if (state == Player.STATE_ENDED) {
                    emit(playerId, "ended", mapOf("openId" to openId))
                }
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    // Match the texture buffer to the video -> a stale buffer size letterboxes or stretches the Texture.
                    producer.setSize(videoSize.width, videoSize.height)
                    emit(
                        playerId,
                        "videoSize",
                        mapOf("width" to videoSize.width, "height" to videoSize.height),
                    )
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e(TAG, "player $playerId error: ${error.errorCodeName}", error)
                // Structured so Dart can ACT on it -> codeName separates the decoder-contention class from network errors.
                // openId lets a stale error from a since-swapped media be dropped -> same convention as firstFrame.
                emit(
                    playerId,
                    "error",
                    mapOf(
                        "openId" to openId,
                        "code" to error.errorCode,
                        "codeName" to error.errorCodeName,
                        "message" to (error.message ?: error.errorCodeName),
                    ),
                )
            }
        }

        // With decoder fallback on, a SoC out of hardware sessions drops to SOFTWARE silently -> no onPlayerError.
        private fun decoderListener(): AnalyticsListener = object : AnalyticsListener {
            override fun onVideoDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) {
                emit(
                    playerId,
                    "decoder",
                    mapOf(
                        "openId" to openId,
                        "name" to decoderName,
                        "isSoftware" to isSoftwareDecoder(decoderName),
                    ),
                )
            }
        }
    }

    // Name-based software-decoder heuristic, mirroring ExoPlayer's own MediaCodecUtil.isSoftwareOnly.
    // MediaCodecInfo.isHardwareAccelerated needs the MediaCodecInfo resolved from the name.
    private fun isSoftwareDecoder(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("c2.android.") ||
            n.startsWith("omx.google.") ||
            n.startsWith("omx.ffmpeg.") ||
            (n.startsWith("omx.") && n.contains(".sw.")) ||
            n.contains("swcodec")
    }

    private fun toUri(url: String): Uri {
        return when {
            url.startsWith("asset:") ||
                url.startsWith("http://") ||
                url.startsWith("https://") ||
                url.startsWith("file://") -> Uri.parse(url)
            else -> Uri.fromFile(File(url))
        }
    }
}
