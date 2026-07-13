package com.hsrapps.arul.feedvideo

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest

/**
 * First-frame stills for live wallpapers, so the browse GRID can show a live item
 * without holding a video decoder for it.
 *
 * A grid of 9-12 tiles cannot run a player per tile: a budget MediaTek SoC has
 * only a handful of concurrent hardware AVC decoders and the rest fall back to
 * software decode, which is exactly the jank this app exists to avoid. So the
 * grid is images-only, and this is where a live item's image comes from.
 *
 * The catalog's MP4s are `+faststart`, so [MediaMetadataRetriever] fetches just
 * the header plus the bytes around the requested timestamp over HTTP — tens of
 * KB, not the whole 4 MB clip.
 *
 * Frames are cached on disk forever (content is immutable and keyed by URL), so
 * a tile costs one ranged read once per install, then nothing.
 */
class VideoThumbnailChannel(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrapps.arul/video_thumb"

        /** Not frame 0: many clips fade in from black and frame 0 is a dead frame. */
        private const val FRAME_US = 500_000L

        /** Grid tiles are ~half screen width; 720px covers that at 3x density. */
        private const val TARGET_W = 720

        /**
         * Concurrent extractions. Each is a network read plus a decode, and the
         * grid can ask for a dozen at once while flinging. Unbounded parallelism
         * here would stall the very scroll it is meant to feed.
         */
        private const val MAX_CONCURRENT = 3
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gate = Semaphore(MAX_CONCURRENT)
    private val cacheDir = File(context.cacheDir, "video_thumbs").apply { mkdirs() }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "thumbnail" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "url is required", null)
                    return
                }
                scope.launch {
                    try {
                        val path = gate.withPermit { extract(url) }
                        withContext(Dispatchers.Main) { result.success(path) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            // Not fatal: the caller falls back to a skeleton tile.
                            result.error("THUMB_FAILED", e.message, null)
                        }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    /** Returns the on-disk path of the cached JPEG, extracting it first if absent. */
    private fun extract(url: String): String {
        val file = File(cacheDir, "${sha1(url)}.jpg")
        if (file.exists() && file.length() > 0) return file.absolutePath

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(url, emptyMap())

            // getScaledFrameAtTime (API 27+) decodes straight to the target size, so
            // a 1024x1824 frame never materializes at full size in a 2GB device's heap.
            val frame: Bitmap? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    val h = TARGET_W * 1824 / 1024 // catalog clips are all 1024x1824
                    retriever.getScaledFrameAtTime(
                        FRAME_US,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        TARGET_W,
                        h,
                    )
                } else {
                    retriever.getFrameAtTime(
                        FRAME_US,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    )
                }
            val bitmap =
                frame ?: throw IllegalStateException("no frame at ${FRAME_US}us")

            // Write to a temp file and rename: a torn JPEG left by a kill mid-write
            // would otherwise be cached forever and the tile would be permanently broken.
            val tmp = File(cacheDir, "${file.name}.tmp")
            tmp.outputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out)
            }
            bitmap.recycle()
            if (!tmp.renameTo(file)) {
                tmp.delete()
                throw IllegalStateException("could not commit thumbnail")
            }
            return file.absolutePath
        } finally {
            retriever.release()
        }
    }

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1")
            .digest(s.toByteArray())
            .joinToString("") { "%02x".format(it) }

    fun dispose() {
        scope.cancel()
    }
}
