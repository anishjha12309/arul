package com.hsrutility.arul.wallpaper

import android.app.WallpaperManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager
import com.hsrutility.arul.BuildConfig
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Downscales oversized wallpaper sources before handing them to WallpaperManager.
 *
 * The platform API still performs its own decode/crop work, but pre-normalizing
 * very large images (2K/4K uploads) reduces the odds of the remote wallpaper
 * service dying under memory pressure on lower-end or heavily customized devices
 * — exactly the budget hardware Arul targets.
 *
 * Adopted from the vendored flutter_wallpaper_plus package, plus ONE behaviour
 * of our own: the bitmap is CENTRE-CROPPED TO THE DISPLAY ASPECT before it is
 * handed over (see [cropToDisplayAspect]) - every source that is not already
 * display-shaped goes through the decode/write path for that reason, not only
 * oversized ones.
 */
class ImageNormalizer(private val context: Context) {

    companion object {
        private const val TAG = "ImageNormalizer"
        private const val MEDIA_CACHE_DIR_NAME = "arul_wallpaper_cache"
        private const val NORMALIZED_FILE_PREFIX = "normalized_"
        private const val MAX_SAFE_LONG_EDGE_PX = 4096
        private const val LARGE_SOURCE_BYTES = 8L * 1024 * 1024
        private const val JPEG_QUALITY = 90
        private const val TARGET_PIXEL_RATIO_THRESHOLD = 2L
        private const val MAX_DECODE_ATTEMPTS = 5

        /**
         * How far the source may sit from the display aspect before it is
         * cropped. 1% is under a pixel row at 1920 and skips the decode/write for
         * a source that already matches the screen.
         */
        private const val ASPECT_TOLERANCE = 0.01f

        /** Bumps the cache key so files written before the crop are not reused. */
        private const val NORMALIZE_VERSION = "crop1"

        /** Debug-only log; the BuildConfig.DEBUG gate strips it from release. */
        private fun logd(msg: String) {
            if (BuildConfig.DEBUG) Log.d(TAG, msg)
        }
    }

    fun normalizeIfNeeded(imageFile: File, target: String): File {
        val bounds = readImageBounds(imageFile) ?: return imageFile
        if (bounds.width <= 0 || bounds.height <= 0) {
            return imageFile
        }

        val targetSize = resolveTargetSize(target)
        val displaySize = getDisplaySize()
        val orientedBounds = if (exifSwapsAxes(imageFile)) {
            ImageBounds(bounds.height, bounds.width)
        } else {
            bounds
        }
        val needsCrop = aspectMismatch(
            orientedBounds.width,
            orientedBounds.height,
            displaySize,
        )
        val sourcePixels = bounds.width.toLong() * bounds.height.toLong()
        val targetPixels = targetSize.width.toLong() * targetSize.height.toLong()
        val sourceLongEdge = max(bounds.width, bounds.height)
        val needsNormalization = bounds.width > targetSize.width ||
                bounds.height > targetSize.height ||
                sourceLongEdge > MAX_SAFE_LONG_EDGE_PX ||
                sourcePixels > targetPixels * TARGET_PIXEL_RATIO_THRESHOLD ||
                imageFile.length() >= LARGE_SOURCE_BYTES ||
                needsCrop

        if (!needsNormalization) {
            return imageFile
        }

        val outputFile = buildOutputFile(imageFile, targetSize)
        if (outputFile.exists() &&
            outputFile.length() > 0 &&
            outputFile.lastModified() >= imageFile.lastModified()
        ) {
            logd(
                "Reusing normalized wallpaper ${outputFile.name} " +
                        "(${outputFile.length()} bytes)"
            )
            return outputFile
        }

        logd(
            "Normalizing wallpaper source " +
                    "from ${bounds.width}x${bounds.height}, ${imageFile.length()} bytes " +
                    "to fit within ${targetSize.width}x${targetSize.height}" +
                    (if (needsCrop) ", crop to ${displaySize.width}x${displaySize.height}" else "")
        )

        val decoded = decodeBitmap(imageFile, targetSize)
            ?: throw IllegalStateException(
                "Image is too large to prepare safely for wallpaper apply."
            )

        val oriented = applyExifOrientation(imageFile, decoded)
        val cropped = cropToDisplayAspect(oriented, displaySize)
        val scaled = scaleBitmapIfNeeded(cropped, targetSize)

        try {
            writeBitmap(scaled, outputFile)
        } finally {
            // Each stage may hand back its input unchanged, so recycle by
            // identity, never by position.
            for (bitmap in listOf(scaled, cropped, oriented, decoded)) {
                if (!bitmap.isRecycled) bitmap.recycle()
            }
        }

        logd(
            "Normalized wallpaper ready: ${outputFile.name} " +
                    "(${outputFile.length()} bytes)"
        )
        return outputFile
    }

    private fun readImageBounds(imageFile: File): ImageBounds? {
        return try {
            val options = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(imageFile.absolutePath, options)
            if (options.outWidth > 0 && options.outHeight > 0) {
                ImageBounds(options.outWidth, options.outHeight)
            } else {
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read image bounds for ${imageFile.name}", e)
            null
        }
    }

    private fun resolveTargetSize(target: String): TargetSize {
        val wallpaperManager = WallpaperManager.getInstance(context)
        val displaySize = getDisplaySize()
        val screenWidth = displaySize.width.coerceAtLeast(1)
        val screenHeight = displaySize.height.coerceAtLeast(1)

        val fallbackWidth = if (target == "lock") {
            screenWidth
        } else {
            (screenWidth * 2).coerceAtMost(MAX_SAFE_LONG_EDGE_PX)
        }

        val desiredWidth = wallpaperManager.desiredMinimumWidth
            .takeIf { it > 0 }
            ?: fallbackWidth
        val desiredHeight = wallpaperManager.desiredMinimumHeight
            .takeIf { it > 0 }
            ?: screenHeight

        return TargetSize(
            width = desiredWidth
                .coerceAtLeast(screenWidth)
                .coerceAtMost(MAX_SAFE_LONG_EDGE_PX),
            height = desiredHeight
                .coerceAtLeast(screenHeight)
                .coerceAtMost(MAX_SAFE_LONG_EDGE_PX),
        )
    }

    private fun getDisplaySize(): TargetSize {
        val resourceMetrics = context.resources.displayMetrics
        var width = resourceMetrics.widthPixels.takeIf { it > 0 } ?: 1080
        var height = resourceMetrics.heightPixels.takeIf { it > 0 } ?: 1920

        val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager?.currentWindowMetrics?.bounds
            if (bounds != null && !bounds.isEmpty) {
                width = max(width, bounds.width())
                height = max(height, bounds.height())
            }
        } else {
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            windowManager?.defaultDisplay?.getRealMetrics(metrics)
            if (metrics.widthPixels > 0) {
                width = max(width, metrics.widthPixels)
            }
            if (metrics.heightPixels > 0) {
                height = max(height, metrics.heightPixels)
            }
        }

        return TargetSize(width = width, height = height)
    }

    private fun decodeBitmap(imageFile: File, targetSize: TargetSize): Bitmap? {
        val bounds = readImageBounds(imageFile) ?: return null
        var sampleSize = calculateInSampleSize(
            sourceWidth = bounds.width,
            sourceHeight = bounds.height,
            targetWidth = targetSize.width,
            targetHeight = targetSize.height,
        )

        repeat(MAX_DECODE_ATTEMPTS) { attempt ->
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize.coerceAtLeast(1)
                inPreferredConfig = Bitmap.Config.RGB_565
                inDither = true
            }

            try {
                val bitmap = BitmapFactory.decodeFile(imageFile.absolutePath, options)
                if (bitmap != null) {
                    return bitmap
                }
                Log.w(
                    TAG,
                    "BitmapFactory returned null for ${imageFile.name} " +
                            "with sampleSize=$sampleSize"
                )
                return null
            } catch (e: OutOfMemoryError) {
                sampleSize *= 2
                Log.w(
                    TAG,
                    "OOM decoding ${imageFile.name}; retrying with sampleSize=$sampleSize " +
                            "(attempt ${attempt + 1}/$MAX_DECODE_ATTEMPTS)",
                    e
                )
            }
        }

        return null
    }

    private fun calculateInSampleSize(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ): Int {
        var sampleSize = 1
        if (sourceWidth <= 0 || sourceHeight <= 0 ||
            targetWidth <= 0 || targetHeight <= 0
        ) {
            return sampleSize
        }

        while ((sourceWidth / sampleSize) > targetWidth * 2 ||
            (sourceHeight / sampleSize) > targetHeight * 2
        ) {
            sampleSize *= 2
        }

        return sampleSize.coerceAtLeast(1)
    }

    /**
     * Centre-crops [bitmap] to the display aspect.
     *
     * WHY (measured 2026-08-25 on a Nothing A001, Android 16, from a launcher
     * screenshot template-matched against the source): a 9:16 source on a
     * 9:19.9 screen is scaled to cover the height and is then WIDER than the
     * screen. With no crop hint the OS keeps that extra width as parallax room
     * and anchors the crop at the LEFT edge of the image; the launcher pans
     * inside that room from its own offset, so the visible window ran from
     * source column 38 to 826 of 1080 - centre 432, not 540 - and every subject
     * landed right of centre. Passing a crop hint still leaves the OS free to
     * extend it for parallax; a bitmap that already has the display shape
     * leaves it nothing to allocate, so the image is centred on every launcher
     * by construction. The cost is the parallax pan, which 9:16 catalog art
     * never had room for anyway.
     *
     * The crop is centred on BOTH axes: a source taller than the screen (a user
     * upload) loses top and bottom equally.
     */
    private fun cropToDisplayAspect(bitmap: Bitmap, display: TargetSize): Bitmap {
        if (!aspectMismatch(bitmap.width, bitmap.height, display)) return bitmap

        val displayAspect = display.width.toFloat() / display.height.toFloat()
        val bitmapAspect = bitmap.width.toFloat() / bitmap.height.toFloat()
        val cropWidth: Int
        val cropHeight: Int
        if (bitmapAspect > displayAspect) {
            cropHeight = bitmap.height
            cropWidth = (bitmap.height * displayAspect).roundToInt()
                .coerceIn(1, bitmap.width)
        } else {
            cropWidth = bitmap.width
            cropHeight = (bitmap.width / displayAspect).roundToInt()
                .coerceIn(1, bitmap.height)
        }
        val left = (bitmap.width - cropWidth) / 2
        val top = (bitmap.height - cropHeight) / 2

        return try {
            Bitmap.createBitmap(bitmap, left, top, cropWidth, cropHeight)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to crop bitmap to ${cropWidth}x${cropHeight}", e)
            bitmap
        }
    }

    private fun aspectMismatch(width: Int, height: Int, display: TargetSize): Boolean {
        if (width <= 0 || height <= 0 || display.width <= 0 || display.height <= 0) {
            return false
        }
        val displayAspect = display.width.toFloat() / display.height.toFloat()
        val sourceAspect = width.toFloat() / height.toFloat()
        return abs(sourceAspect - displayAspect) / displayAspect > ASPECT_TOLERANCE
    }

    /** True when the EXIF orientation rotates by 90/270 degrees, swapping width and height. */
    private fun exifSwapsAxes(imageFile: File): Boolean {
        val orientation = try {
            ExifInterface(imageFile.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
        } catch (e: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        return when (orientation) {
            ExifInterface.ORIENTATION_TRANSPOSE,
            ExifInterface.ORIENTATION_ROTATE_90,
            ExifInterface.ORIENTATION_TRANSVERSE,
            ExifInterface.ORIENTATION_ROTATE_270 -> true
            else -> false
        }
    }

    private fun applyExifOrientation(imageFile: File, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(imageFile.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read EXIF orientation for ${imageFile.name}", e)
            ExifInterface.ORIENTATION_NORMAL
        }

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> {
                matrix.setScale(-1f, 1f)
            }

            ExifInterface.ORIENTATION_ROTATE_180 -> {
                matrix.setRotate(180f)
            }

            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setScale(1f, -1f)
            }

            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }

            ExifInterface.ORIENTATION_ROTATE_90 -> {
                matrix.setRotate(90f)
            }

            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }

            ExifInterface.ORIENTATION_ROTATE_270 -> {
                matrix.setRotate(270f)
            }

            else -> return bitmap
        }

        return try {
            Bitmap.createBitmap(
                bitmap,
                0,
                0,
                bitmap.width,
                bitmap.height,
                matrix,
                true
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to rotate bitmap for ${imageFile.name}", e)
            bitmap
        }
    }

    private fun scaleBitmapIfNeeded(bitmap: Bitmap, targetSize: TargetSize): Bitmap {
        val widthScale = targetSize.width.toFloat() / bitmap.width.toFloat()
        val heightScale = targetSize.height.toFloat() / bitmap.height.toFloat()
        val scale = min(1f, min(widthScale, heightScale))

        if (scale >= 0.999f) {
            return bitmap
        }

        val scaledWidth = max(1, (bitmap.width * scale).toInt())
        val scaledHeight = max(1, (bitmap.height * scale).toInt())

        return try {
            Bitmap.createScaledBitmap(bitmap, scaledWidth, scaledHeight, true)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to scale bitmap to ${scaledWidth}x${scaledHeight}", e)
            bitmap
        }
    }

    private fun writeBitmap(bitmap: Bitmap, outputFile: File) {
        val directory = outputFile.parentFile
            ?: throw IllegalStateException("Normalized wallpaper directory missing.")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not create normalized wallpaper directory.")
        }

        val tempFile = File(directory, "${outputFile.name}.tmp")

        try {
            FileOutputStream(tempFile).use { output ->
                val compressed = bitmap.compress(
                    Bitmap.CompressFormat.JPEG,
                    JPEG_QUALITY,
                    output
                )
                output.flush()
                if (!compressed) {
                    throw IllegalStateException("Bitmap compression failed.")
                }
            }

            if (!tempFile.renameTo(outputFile)) {
                tempFile.copyTo(outputFile, overwrite = true)
                tempFile.delete()
            }

            outputFile.setLastModified(System.currentTimeMillis())
        } catch (e: Exception) {
            tempFile.delete()
            throw e
        }
    }

    private fun buildOutputFile(imageFile: File, targetSize: TargetSize): File {
        val dir = File(context.cacheDir, MEDIA_CACHE_DIR_NAME)
        val key = buildString {
            append(imageFile.absolutePath)
            append(':')
            append(imageFile.lastModified())
            append(':')
            append(imageFile.length())
            append(':')
            append(targetSize.width)
            append('x')
            append(targetSize.height)
            append(':')
            append(JPEG_QUALITY)
            append(':')
            append(NORMALIZE_VERSION)
        }
        val fileName = "${NORMALIZED_FILE_PREFIX}${hashKey(key)}.jpg"
        return File(dir, fileName)
    }

    private fun hashKey(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = digest.digest(input.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }.take(32)
    }

    private data class ImageBounds(
        val width: Int,
        val height: Int,
    )

    private data class TargetSize(
        val width: Int,
        val height: Int,
    )
}
