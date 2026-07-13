package com.hsrapps.arul.wallpaper

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
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.min

/**
 * Downscales oversized wallpaper sources before handing them to WallpaperManager.
 *
 * The platform API still performs its own decode/crop work, but pre-normalizing
 * very large images (2K/4K uploads) reduces the odds of the remote wallpaper
 * service dying under memory pressure on lower-end or heavily customized devices
 * — exactly the budget hardware Arul targets.
 *
 * Adopted from the vendored flutter_wallpaper_plus package. The only change is
 * the package + the cache dir name (arul_wallpaper_cache).
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
    }

    fun normalizeIfNeeded(imageFile: File, target: String): File {
        val bounds = readImageBounds(imageFile) ?: return imageFile
        if (bounds.width <= 0 || bounds.height <= 0) {
            return imageFile
        }

        val targetSize = resolveTargetSize(target)
        val sourcePixels = bounds.width.toLong() * bounds.height.toLong()
        val targetPixels = targetSize.width.toLong() * targetSize.height.toLong()
        val sourceLongEdge = max(bounds.width, bounds.height)
        val needsNormalization = bounds.width > targetSize.width ||
                bounds.height > targetSize.height ||
                sourceLongEdge > MAX_SAFE_LONG_EDGE_PX ||
                sourcePixels > targetPixels * TARGET_PIXEL_RATIO_THRESHOLD ||
                imageFile.length() >= LARGE_SOURCE_BYTES

        if (!needsNormalization) {
            return imageFile
        }

        val outputFile = buildOutputFile(imageFile, targetSize)
        if (outputFile.exists() &&
            outputFile.length() > 0 &&
            outputFile.lastModified() >= imageFile.lastModified()
        ) {
            Log.d(
                TAG,
                "Reusing normalized wallpaper ${outputFile.name} " +
                        "(${outputFile.length()} bytes)"
            )
            return outputFile
        }

        Log.d(
            TAG,
            "Normalizing wallpaper source " +
                    "from ${bounds.width}x${bounds.height}, ${imageFile.length()} bytes " +
                    "to fit within ${targetSize.width}x${targetSize.height}"
        )

        val decoded = decodeBitmap(imageFile, targetSize)
            ?: throw IllegalStateException(
                "Image is too large to prepare safely for wallpaper apply."
            )

        val oriented = applyExifOrientation(imageFile, decoded)
        val scaled = scaleBitmapIfNeeded(oriented, targetSize)

        try {
            writeBitmap(scaled, outputFile)
        } finally {
            if (scaled !== oriented && !oriented.isRecycled) {
                oriented.recycle()
            }
            if (oriented !== decoded && !decoded.isRecycled) {
                decoded.recycle()
            }
            if (!scaled.isRecycled) {
                scaled.recycle()
            }
        }

        Log.d(
            TAG,
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
