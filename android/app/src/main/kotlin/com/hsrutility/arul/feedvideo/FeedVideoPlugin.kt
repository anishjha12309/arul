package com.hsrutility.arul.feedvideo

import android.content.Context
import android.media.MediaCodecList
import android.net.Uri
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

// The whole reason this exists is player + surface REUSE -> the Dart pool keeps a few players alive all session.
// A swipe moves a player to a new clip with open() == setMediaItem + prepare on a SURVIVING ExoPlayer.
// Never dispose+recreate per swipe -> that churned the `BLASTBufferQueue ... max frames` flood on budget MediaTek SoCs.
// ExoPlayer must be created and driven on the MAIN thread -> MethodChannel handlers already arrive there.
// An unknown or stale playerId is a success no-op -> a call arriving just after dispose() must never throw.
// The first painted frame is reported natively via onRenderedFirstFrame -> no width + surface-rect settle dance.
// That callback can fire for a PREVIOUS media around a swap -> every open() bumps an openId echoed on the event.
// Dart drops a stale first-frame on that id -> belt-and-braces with its own open-token guard.
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
        // A small bufferForPlaybackMs paints the first frame after a small read -> faster first paint on 4G.
        // Media3 constraints: maxBufferMs >= minBufferMs, and bufferForPlaybackMs <= minBufferMs.
        private const val MIN_BUFFER_MS = 2_000
        private const val MAX_BUFFER_MS = 4_000
        private const val BUFFER_FOR_PLAYBACK_MS = 250
        private const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 1_000
    }

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also {
        it.setMethodCallHandler(this)
    }
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL).also {
        it.setStreamHandler(this)
    }

    /** Single broadcast sink; events are tagged with `playerId` so Dart fans out. */
    private var eventSink: EventChannel.EventSink? = null

    private val players = HashMap<Int, PooledSurfacePlayer>()
    private var nextPlayerId = 1

    // ─── EventChannel.StreamHandler ───────────────────────────────────────────

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

    // ─── MethodChannel.MethodCallHandler ──────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // `audio` is opt-in and defaults to false -> every existing caller keeps the muted, no-focus player.
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
                // Fire-and-forget; Dart never waits on it.
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
                    // The openId of the most recent frame actually painted, 0 when nothing has painted yet.
                    // It lets Dart's reveal timeout tell a LOST first-frame event from a clip that has not decoded.
                    // So a reused player is never force-revealed onto its previous clip's frozen frame.
                    // -1 for a stale or unknown id.
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

    // ─── Operations ───────────────────────────────────────────────────────────

    // The producer and player survive every clip swap -> only [disposePlayer] tears them down.
    private fun create(audio: Boolean): Map<String, Any> {
        logDecoderCapsOnce()
        val playerId = nextPlayerId++
        if (audio) Log.i(TAG, "audible create: player $playerId")
        val pooled = PooledSurfacePlayer(playerId, audio)
        players[playerId] = pooled
        return mapOf("playerId" to playerId, "textureId" to pooled.textureId)
    }

    // One-shot logcat diagnostic -> what the SoC CLAIMS its concurrent decoder ceiling is for the feed's codecs.
    // Budget SoCs often report or enforce 2, below the feed's previous+current+next window of 3.
    // That is the signature of the "third wallpaper never renders" bug.
    // Diagnostic ONLY -> the number lies in both directions, so Dart adapts on real decoder errors instead.
    private var loggedDecoderCaps = false
    private fun logDecoderCapsOnce() {
        if (loggedDecoderCaps) return
        loggedDecoderCaps = true
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
    }

    /** Swaps media on a SURVIVING player: setMediaItem + prepare, no surface churn. */
    private fun open(
        playerId: Int,
        url: String,
        playWhenReady: Boolean,
        looping: Boolean,
    ): Long {
        val pooled = players[playerId] ?: return -1 // stale id → no-op
        return pooled.open(url, playWhenReady, looping)
    }

    // Pay the DNS + TCP + TLS cost to the CDN BEFORE the clip is opened.
    // Measured on device: a cold open reached its first frame in 1499ms, a pooled one moments later in 312ms.
    // The ~1.19s difference is handshake, not bytes -> the clip needs about 18 KB to start, served from cache.
    // ExoPlayer's DefaultHttpDataSource is built on HttpURLConnection, whose keep-alive pool is per-JVM.
    // So a request issued here from the same stack is the one the player reuses.
    // It must NOT be a Dart-side fetch -> dart:io has its own pool and would warm nothing the player can see.
    // One byte completes the handshake -> the body is irrelevant.
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
                // Best effort only -> a failed warm just means the open pays the handshake itself.
                Log.w(TAG, "connection warm failed", e)
            }
        }.start()
    }

    private fun disposePlayer(playerId: Int) {
        players.remove(playerId)?.release()
    }

    private fun disposeAll() {
        val all = players.values.toList()
        players.clear()
        for (p in all) p.release()
    }

    /** Called from MainActivity.cleanUpFlutterEngine so a torn-down engine leaks nothing. */
    fun dispose() {
        disposeAll()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    /** Broadcast one event tagged with its playerId to the single Dart stream. */
    private fun emit(playerId: Int, event: String, extra: Map<String, Any>? = null) {
        val sink = eventSink ?: return
        val payload = HashMap<String, Any>()
        payload["playerId"] = playerId
        payload["event"] = event
        if (extra != null) payload.putAll(extra)
        sink.success(payload)
    }

    // ─── One pooled player + its reusable surface ─────────────────────────────

    // One ExoPlayer plus its SurfaceProducer, created ONCE and reused across feed indices -> [open] only swaps media.
    // It implements SurfaceProducer.Callback so a recycled surface is re-attached in [onSurfaceAvailable].
    // That is what makes the pool Impeller-compatible and lets it survive backgrounding without recreating players.
    private inner class PooledSurfacePlayer(
        private val playerId: Int,
        // FALSE for the feed and the auth background -> a preview must never duck the user's music.
        // TRUE only for the paywall's onboarding clip -> it is a voiceover, so silent it carries no message at all.
        private val withAudio: Boolean = false,
    ) : TextureRegistry.SurfaceProducer.Callback {

        private val producer: TextureRegistry.SurfaceProducer =
            textureRegistry.createSurfaceProducer()
        val textureId: Long = producer.id()

        /** Bumped per [open]; echoed on `firstFrame` so Dart drops stale frames. */
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
                .setBufferDurationsMs(
                    MIN_BUFFER_MS,
                    MAX_BUFFER_MS,
                    BUFFER_FOR_PLAYBACK_MS,
                    BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
                )
                .build()

            // Budget SoCs fail hardware codec init when several players are alive -> concurrent-instance limits.
            // Fall back to a lower-priority, possibly software decoder instead of hard-failing.
            // A paused window neighbour only needs its first frame decoded -> a slower decoder is fine there.
            val renderersFactory = DefaultRenderersFactory(context)
                .setEnableDecoderFallback(true)

            player = ExoPlayer.Builder(context, renderersFactory)
                .setLoadControl(loadControl)
                // A muted preview NEVER takes audio focus -> it would duck other apps and pause music while browsing.
                // An audible player asks for focus like any media app -> a call pauses it, and music stops rather than clashes.
                .setAudioAttributes(
                    if (withAudio) {
                        AudioAttributes.Builder()
                            .setUsage(C.USAGE_MEDIA)
                            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                            .build()
                    } else {
                        AudioAttributes.DEFAULT
                    },
                    /* handleAudioFocus = */ withAudio,
                )
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
            // AUDIBLE players only, i.e. the paywall's onboarding clip and never the feed.
            // The cuts are the same footage -> a screenshot cannot tell the languages apart.
            // Only this line confirms the deep link's `lang` survived all the way to the media.
            if (withAudio) {
                audibleOpenAt = SystemClock.elapsedRealtime()
                Log.i(TAG, "audible open: $url")
            }
            try {
                player.repeatMode =
                    if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                player.setMediaItem(MediaItem.fromUri(toUri(url)))
                player.playWhenReady = playWhenReady
                player.prepare()
            } catch (e: Exception) {
                Log.e(TAG, "open failed for player $playerId", e)
                // Tag with THIS open's id -> Dart drops it if a newer open has since swapped in.
                // Tag with a distinct codeName -> Dart recognises a non-decoder open failure and schedules a re-open.
                // Without openId Dart treated it as current; without a codeName it fell through as ERROR_CODE_UNSPECIFIED.
                // That is neither a decoder class nor recoverable -> the card was left stranded on its poster.
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
        }

        // Runtime mute and unmute for an AUDIBLE player -> focus was decided at construction.
        // A player built muted never asks for focus -> setting a volume on one changes nothing the user can hear.
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
            } catch (e: Exception) {
                Log.w(TAG, "stop failed for $playerId", e)
            }
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

        // ── SurfaceProducer.Callback (Impeller / backgrounding safety) ─────────

        override fun onSurfaceAvailable() {
            // The old Surface was reclaimed and a fresh one is ready -> re-attach it so the player renders after resume.
            try {
                player.setVideoSurface(producer.surface)
            } catch (e: Exception) {
                Log.w(TAG, "onSurfaceAvailable re-attach failed for $playerId", e)
            }
        }

        override fun onSurfaceCleanup() {
            // The Surface is about to become invalid -> detach it so ExoPlayer never renders into a dead Surface.
            // onSurfaceAvailable re-attaches it.
            try {
                player.clearVideoSurface()
            } catch (e: Exception) {
                Log.w(TAG, "onSurfaceCleanup failed for $playerId", e)
            }
        }

        private fun playerListener(): Player.Listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                // Record what was painted for the paintedOpenId query, and tag the event with the current openId.
                // Dart then drops a first-frame belonging to a since-swapped media.
                lastPaintedOpenId = openId
                if (withAudio && audibleOpenAt > 0L) {
                    val ms = SystemClock.elapsedRealtime() - audibleOpenAt
                    Log.i(TAG, "audible first frame: +${ms}ms")
                }
                emit(playerId, "firstFrame", mapOf("openId" to openId))
            }

            // STATE_ENDED is only reached by a NON-looping open -> a looping player re-enters BUFFERING/READY instead.
            // Tagged with openId like the rest -> a swap cannot deliver a stale "ended".
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

            // Decoder-selection reporting lives in decoderListener() below.
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

        // Reports which video decoder each open() actually got.
        // With decoder fallback on, a SoC out of hardware sessions drops to SOFTWARE silently -> no onPlayerError.
        // The sw path is where gralloc stride padding leaks as the green edge strip (flutter/flutter#174026).
        // It is also where the battery and thermal cost lives.
        // Dart reads `isSoftware` as a decoder-contention signal -> it shrinks the pool window to free a hw session.
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
    // The platform sw codecs are `c2.android.*` and `OMX.google.*`; some vendors mark theirs with `.sw.`.
    // MediaCodecInfo.isHardwareAccelerated needs the MediaCodecInfo resolved from the name.
    // The prefix check is what ExoPlayer itself trusts -> match that.
    private fun isSoftwareDecoder(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("c2.android.") ||
            n.startsWith("omx.google.") ||
            n.startsWith("omx.ffmpeg.") ||
            (n.startsWith("omx.") && n.contains(".sw.")) ||
            n.contains("swcodec")
    }

    // Builds a Uri DefaultDataSource can open for all three source shapes the feed uses.
    // A Flutter asset and an https CDN URL pass through; a local absolute path is wrapped as a `file://` Uri.
    private fun toUri(url: String): Uri {
        return when {
            url.startsWith("asset:") ||
                url.startsWith("http://") ||
                url.startsWith("https://") ||
                url.startsWith("file://") -> Uri.parse(url)
            else -> Uri.fromFile(File(url)) // local absolute path
        }
    }
}
