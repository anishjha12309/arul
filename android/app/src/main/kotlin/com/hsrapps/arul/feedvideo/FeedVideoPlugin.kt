package com.hsrapps.arul.feedvideo

import android.content.Context
import android.media.MediaCodecList
import android.net.Uri
import android.util.Log
import androidx.media3.common.AudioAttributes
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

/**
 * Native Media3 ExoPlayer texture pool, exposed to Dart over a MethodChannel
 * ([METHOD_CHANNEL]) + broadcast EventChannel ([EVENT_CHANNEL]).
 *
 * This replaces the old `media_kit` (libmpv) feed stack. Its whole reason to
 * exist is **player + surface REUSE**: the Dart `VideoPreloadController` keeps a
 * tiny fixed pool of these players alive for the whole session and moves a
 * player to a new clip with `open()` (== `setMediaItem` + `prepare` on a
 * SURVIVING ExoPlayer that keeps its `SurfaceProducer`), never dispose+recreate
 * per swipe. Recreating a surface per swipe is what churned the
 * `BLASTBufferQueue ... max frames` flood + settle-jank on budget MediaTek SoCs.
 *
 * Threading: ExoPlayer must be created and driven on the main thread. Flutter
 * MethodChannel handlers already arrive on the platform main thread, so every
 * handler below runs there directly. Unknown / stale playerIds are treated as a
 * success no-op — a call arriving just after `dispose()` must never throw.
 *
 * Reveal signalling: instead of media_kit's width + surface-rect settle dance,
 * the surface's first painted frame is reported natively via
 * [Player.Listener.onRenderedFirstFrame] as a `firstFrame` event. Because that
 * callback can fire for a PREVIOUS media around a `setMediaItem` swap, every
 * `open()` bumps a per-player `openId` that is echoed back on the event, so Dart
 * can drop a stale first-frame deterministically (belt-and-suspenders with its
 * own open-token guard).
 */
class FeedVideoPlugin(
    private val context: Context,
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.hsrapps.arul/feed_video"
        const val EVENT_CHANNEL = "com.hsrapps.arul/feed_video_events"
        private const val TAG = "FeedVideoPlugin"

        // Small demuxer/loading budget — mirrors the old libmpv 4 MB / ~2-4s
        // readahead cap. A looping short preview never needs a deep buffer, and a
        // small bufferForPlaybackMs makes the first frame paint after a small
        // read (faster first paint on 4G). Constraints (Media3):
        //   maxBufferMs >= minBufferMs, bufferForPlaybackMs <= minBufferMs.
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
        // The Dart side keeps ONE process-global subscription on this channel
        // (all pools share it via the channel hub — see FeedVideoPlayerPool), so
        // native gets exactly one live sink and no second listener can clobber
        // the first. Flutter's stream handler always delivers onCancel for the
        // previous listener before onListen for a replacement, so a plain assign
        // is correct: `events` is always the newest, live sink.
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        // Flutter guarantees onCancel(old) precedes onListen(new) on the single
        // main thread, so a cancel here always refers to the current sink; null
        // it. (With the single Dart subscription there is only ever one sink to
        // begin with — this fires on final teardown.)
        eventSink = null
    }

    // ─── MethodChannel.MethodCallHandler ──────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> result.success(create())
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
            // Never surface a native crash to Dart mid-scroll; log + no-op.
            Log.e(TAG, "onMethodCall(${call.method}) failed", e)
            result.success(null)
        }
    }

    // ─── Operations ───────────────────────────────────────────────────────────

    /**
     * Creates an ExoPlayer bound to a fresh Flutter [SurfaceProducer] texture and
     * returns `{playerId, textureId}`. The producer + player survive every clip
     * swap; only [disposePlayer] tears them down.
     */
    private fun create(): Map<String, Any> {
        logDecoderCapsOnce()
        val playerId = nextPlayerId++
        val pooled = PooledSurfacePlayer(playerId)
        players[playerId] = pooled
        return mapOf("playerId" to playerId, "textureId" to pooled.textureId)
    }

    /**
     * One-shot logcat diagnostic: what the SoC CLAIMS its concurrent decoder
     * ceiling is for the feed's codecs. Budget SoCs often report (or actually
     * enforce) 2, below the feed's previous+current+next window of 3 — the
     * signature of the "third wallpaper never renders" bug. Diagnostic only: the
     * reported number lies in both directions, so the Dart controller adapts on
     * REAL decoder errors instead of trusting it.
     */
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

    /**
     * One ExoPlayer + its [TextureRegistry.SurfaceProducer]. Created ONCE and
     * reused across feed indices — [open] only swaps media. Implements
     * [TextureRegistry.SurfaceProducer.Callback] so that, on Impeller / after a
     * backgrounding-driven surface recycle, the player's video output surface is
     * re-attached ([onSurfaceAvailable]) — this is what makes the texture pool
     * Impeller-compatible and survive backgrounding without recreating players.
     */
    private inner class PooledSurfacePlayer(private val playerId: Int) :
        TextureRegistry.SurfaceProducer.Callback {

        private val producer: TextureRegistry.SurfaceProducer =
            textureRegistry.createSurfaceProducer()
        val textureId: Long = producer.id()

        /** Bumped per [open]; echoed on `firstFrame` so Dart drops stale frames. */
        private var openId = 0

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

            // Budget SoCs can fail hardware codec init when several players are
            // alive at once (concurrent-instance limits). Fall back to a
            // lower-priority (possibly software) decoder instead of hard-failing
            // — a paused window neighbour only needs its first frame decoded, so
            // a slower decoder is fine. Capable devices never hit the fallback.
            val renderersFactory = DefaultRenderersFactory(context)
                .setEnableDecoderFallback(true)

            player = ExoPlayer.Builder(context, renderersFactory)
                .setLoadControl(loadControl)
                // Muted preview: never take audio focus (would duck other apps'
                // audio and pause the user's music while just browsing).
                .setAudioAttributes(AudioAttributes.DEFAULT, /* handleAudioFocus = */ false)
                .build()
                .apply {
                    volume = 0f
                    repeatMode = Player.REPEAT_MODE_OFF
                    setVideoSurface(producer.surface)
                    addListener(playerListener())
                    addAnalyticsListener(decoderListener())
                }
        }

        fun open(url: String, playWhenReady: Boolean, looping: Boolean): Long {
            val id = ++openId
            try {
                player.repeatMode =
                    if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
                player.setMediaItem(MediaItem.fromUri(toUri(url)))
                player.playWhenReady = playWhenReady
                player.prepare()
            } catch (e: Exception) {
                Log.e(TAG, "open failed for player $playerId", e)
                emit(playerId, "error", mapOf("message" to (e.message ?: "open failed")))
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

        /**
         * Stops playback and moves the player to STATE_IDLE, which releases its
         * codec (the player holds "only limited resources" when idle) while the
         * player object AND its SurfaceProducer survive — a later [open]
         * re-prepares on the same surface, no churn. Used by Dart to hand a
         * scarce decoder to a higher-priority index on codec-starved SoCs;
         * never called per scroll.
         */
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
            // The old Surface was reclaimed and a fresh one is ready — re-attach
            // it so the surviving player keeps rendering after resume.
            try {
                player.setVideoSurface(producer.surface)
            } catch (e: Exception) {
                Log.w(TAG, "onSurfaceAvailable re-attach failed for $playerId", e)
            }
        }

        override fun onSurfaceCleanup() {
            // Surface is about to become invalid (e.g. low memory / backgrounded).
            // Detach it from the player so ExoPlayer doesn't render into a dead
            // Surface; it is re-attached in onSurfaceAvailable.
            try {
                player.clearVideoSurface()
            } catch (e: Exception) {
                Log.w(TAG, "onSurfaceCleanup failed for $playerId", e)
            }
        }

        private fun playerListener(): Player.Listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                // Tag with the current openId so Dart drops a first-frame that
                // belongs to a since-swapped media.
                emit(playerId, "firstFrame", mapOf("openId" to openId))
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    // Match the texture buffer to the video so the Texture widget
                    // isn't letterboxed/stretched by a stale buffer size.
                    producer.setSize(videoSize.width, videoSize.height)
                    emit(
                        playerId,
                        "videoSize",
                        mapOf("width" to videoSize.width, "height" to videoSize.height),
                    )
                }
            }

            // (decoder-selection reporting lives in decoderListener() below)
            override fun onPlayerError(error: PlaybackException) {
                Log.e(TAG, "player $playerId error: ${error.errorCodeName}", error)
                // Structured so Dart can act on it: codeName distinguishes the
                // budget-SoC decoder-contention class (ERROR_CODE_DECODER_* /
                // ERROR_CODE_DECODING_*) from network errors, and openId lets a
                // stale error from a since-swapped media be dropped (same
                // convention as firstFrame).
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

        /**
         * Reports which video decoder each `open()` actually got. With
         * [DefaultRenderersFactory.setEnableDecoderFallback] a budget SoC that
         * is out of hardware-decoder sessions falls back to the SOFTWARE
         * decoder SILENTLY (no onPlayerError) — and the sw path is where
         * gralloc stride padding leaks as the green edge strip
         * (flutter/flutter#174026) AND where battery/thermal cost lives. Dart
         * uses `isSoftware` as a decoder-contention signal to shrink its pool
         * window, freeing a hw session for the visible card.
         */
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

    /**
     * Name-based software-decoder heuristic (mirrors ExoPlayer's internal
     * MediaCodecUtil.isSoftwareOnly): the platform sw codecs are
     * `c2.android.*` / `OMX.google.*`; some vendors mark theirs with `.sw.`.
     * MediaCodecInfo.isHardwareAccelerated exists but requires resolving the
     * MediaCodecInfo from the name — the prefix check is what ExoPlayer itself
     * trusts, so match that.
     */
    private fun isSoftwareDecoder(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("c2.android.") ||
            n.startsWith("omx.google.") ||
            n.startsWith("omx.ffmpeg.") ||
            (n.startsWith("omx.") && n.contains(".sw.")) ||
            n.contains("swcodec")
    }

    /**
     * Builds a Uri ExoPlayer's DefaultDataSource can open for all three source
     * shapes the feed uses:
     *   - a Flutter asset  → `asset:///flutter_assets/...`  (passed through)
     *   - an https CDN URL → passed through
     *   - a local absolute file path → wrapped as a proper `file://` Uri
     */
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
