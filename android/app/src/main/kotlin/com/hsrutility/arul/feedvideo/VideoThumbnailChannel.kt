package com.hsrutility.arul.feedvideo

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

// First-frame stills for live wallpapers -> the browse GRID shows a live item without holding a decoder for it.
// A grid of 9-12 tiles cannot run a player per tile -> a budget SoC has a handful of concurrent hardware AVC decoders.
// The rest fall back to software decode -> exactly the jank this app exists to avoid, so the grid is images-only.
// The catalog's MP4s are `+faststart` -> MediaMetadataRetriever fetches the header plus bytes around the timestamp.
// That is tens of KB over HTTP, not the whole clip.
// Frames are cached on disk forever, keyed by URL, because the content is immutable -> one ranged read per install.
class VideoThumbnailChannel(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/video_thumb"

        /** Not frame 0 -> many clips fade in from black, so frame 0 is a dead frame. */
        private const val FRAME_US = 500_000L

        /** Grid tiles are ~half screen width; 720px covers that at 3x density. */
        private const val TARGET_W = 720

        // Each extraction is a network read plus a decode, and a fling can ask for a dozen at once.
        // Unbounded parallelism here would stall the very scroll it is meant to feed.
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
                            // Not fatal -> the caller falls back to a skeleton tile.
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

            // getScaledFrameAtTime decodes straight to the target size -> a full-size frame never lands in a 2GB heap.
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

            // Write to a temp file and rename -> a torn JPEG from a kill mid-write would be cached forever otherwise.
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
