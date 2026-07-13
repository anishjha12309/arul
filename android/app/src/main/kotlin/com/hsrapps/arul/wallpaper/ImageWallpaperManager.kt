package com.hsrapps.arul.wallpaper

import android.app.WallpaperManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream

/**
 * Sets static image wallpapers via Android's WallpaperManager.
 *
 * Adopted from the vendored flutter_wallpaper_plus ImageWallpaperManager and
 * trimmed to throw [WallpaperApplyException] on failure (instead of returning a
 * ResultPayload), which is what the Dart apply service expects.
 *
 * Design decisions retained from the vendored code (all earned on real devices):
 *  1. Primary path is setStream() (memory-efficient), with a decoded-bitmap
 *     fallback for lock-sensitive OEMs where the stream path silently no-ops.
 *  2. Pre-flight isWallpaperSupported / isSetWallpaperAllowed checks (managed
 *     and kiosk devices block wallpaper changes).
 *  3. FLAG_SYSTEM / FLAG_LOCK handled per API level (minSdk 24 ⇒ always flagged).
 *  4. "both" writes home then lock sequentially with a short gap (some OEMs drop
 *     the second write if issued back-to-back), each with the bitmap fallback.
 *  5. Sources are normalized (downscaled) first to avoid OOM on budget SoCs.
 */
class ImageWallpaperManager(private val context: Context) {

    companion object {
        private const val TAG = "ImageWallpaperManager"
    }

    private val imageNormalizer: ImageNormalizer by lazy {
        ImageNormalizer(context)
    }

    /**
     * Sets [imageFile] as the wallpaper on [target] ("home" | "lock" | "both").
     * Runs entirely on Dispatchers.IO. Throws [WallpaperApplyException] on
     * failure; returns normally on success.
     */
    suspend fun setWallpaper(imageFile: File, target: String) =
        withContext(Dispatchers.IO) {
            val wallpaperManager = WallpaperManager.getInstance(context)

            if (!wallpaperManager.isWallpaperSupported) {
                throw WallpaperApplyException(
                    "unsupported",
                    "Wallpaper is not supported on this device.",
                )
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                !wallpaperManager.isSetWallpaperAllowed
            ) {
                throw WallpaperApplyException(
                    "manufacturerRestriction",
                    "Setting wallpaper is blocked by device policy " +
                            "(MDM, parental controls, or manufacturer restriction).",
                )
            }

            validateFile(imageFile)

            val preparedFile = imageNormalizer.normalizeIfNeeded(imageFile, target)
            validateFile(preparedFile)

            Log.d(
                TAG,
                "Setting wallpaper: file=${preparedFile.name}, " +
                        "size=${preparedFile.length()}, target=$target"
            )

            try {
                when (target) {
                    "home" -> setWallpaperForFlags(
                        wallpaperManager,
                        preparedFile,
                        WallpaperManager.FLAG_SYSTEM
                    )

                    "lock" -> setLockWithCompatibilityFallback(
                        wallpaperManager,
                        preparedFile
                    )

                    "both" -> setBothWithCompatibilityFallback(
                        wallpaperManager,
                        preparedFile
                    )

                    else -> setWallpaperForFlags(
                        wallpaperManager,
                        preparedFile,
                        WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK
                    )
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "SecurityException setting wallpaper", e)
                throw WallpaperApplyException(
                    "permissionDenied",
                    "Permission denied: ${e.message ?: "SET_WALLPAPER required"}",
                )
            } catch (e: OutOfMemoryError) {
                Log.e(TAG, "OOM setting wallpaper", e)
                throw WallpaperApplyException(
                    "applyFailed",
                    "Image is too large to process. Try a smaller image.",
                )
            } catch (e: WallpaperApplyException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Unexpected error setting wallpaper", e)
                throw WallpaperApplyException(
                    "applyFailed",
                    "Failed to set wallpaper: ${e.message ?: "Unknown error"}",
                )
            }

            Log.d(TAG, "Wallpaper set successfully")
        }

    private fun setLockWithCompatibilityFallback(
        wallpaperManager: WallpaperManager,
        imageFile: File
    ) {
        val restrictiveOem = OemPolicy.isRestrictiveOem()
        val beforeLockId = safeGetWallpaperId(wallpaperManager, WallpaperManager.FLAG_LOCK)

        setWallpaperForFlags(wallpaperManager, imageFile, WallpaperManager.FLAG_LOCK)

        val lockChanged =
            didWallpaperIdChange(wallpaperManager, WallpaperManager.FLAG_LOCK, beforeLockId)

        if (restrictiveOem || !lockChanged) {
            Log.d(TAG, "Lock fallback (restrictiveOem=$restrictiveOem, changed=$lockChanged)")
            withDecodedBitmap(imageFile) { bitmap ->
                setWallpaperForFlagsBitmap(wallpaperManager, bitmap, WallpaperManager.FLAG_LOCK)
            }
        }
    }

    private fun setBothWithCompatibilityFallback(
        wallpaperManager: WallpaperManager,
        imageFile: File
    ) {
        val restrictiveOem = OemPolicy.isRestrictiveOem()
        val beforeSystemId = safeGetWallpaperId(wallpaperManager, WallpaperManager.FLAG_SYSTEM)
        val beforeLockId = safeGetWallpaperId(wallpaperManager, WallpaperManager.FLAG_LOCK)

        setWallpaperForFlags(wallpaperManager, imageFile, WallpaperManager.FLAG_SYSTEM)
        val systemChanged =
            didWallpaperIdChange(wallpaperManager, WallpaperManager.FLAG_SYSTEM, beforeSystemId)
        if (restrictiveOem || !systemChanged) {
            withDecodedBitmap(imageFile) { bitmap ->
                setWallpaperForFlagsBitmap(wallpaperManager, bitmap, WallpaperManager.FLAG_SYSTEM)
            }
        }

        sleepBetweenSequentialWrites()

        setWallpaperForFlags(wallpaperManager, imageFile, WallpaperManager.FLAG_LOCK)
        val lockChanged =
            didWallpaperIdChange(wallpaperManager, WallpaperManager.FLAG_LOCK, beforeLockId)
        if (restrictiveOem || !lockChanged) {
            withDecodedBitmap(imageFile) { bitmap ->
                setWallpaperForFlagsBitmap(wallpaperManager, bitmap, WallpaperManager.FLAG_LOCK)
            }
        }
    }

    private fun setWallpaperForFlags(
        wallpaperManager: WallpaperManager,
        imageFile: File,
        flags: Int
    ) {
        FileInputStream(imageFile).use { stream ->
            // visibleCropHint=null → system handles cropping; allowBackup=true.
            wallpaperManager.setStream(stream, null, true, flags)
        }
    }

    private fun setWallpaperForFlagsBitmap(
        wallpaperManager: WallpaperManager,
        bitmap: Bitmap,
        flags: Int
    ) {
        wallpaperManager.setBitmap(bitmap, null, true, flags)
    }

    private inline fun withDecodedBitmap(imageFile: File, block: (Bitmap) -> Unit) {
        val bitmap = BitmapFactory.decodeFile(imageFile.absolutePath)
            ?: throw IllegalArgumentException(
                "Failed to decode prepared wallpaper bitmap: ${imageFile.name}"
            )
        try {
            block(bitmap)
        } finally {
            if (!bitmap.isRecycled) bitmap.recycle()
        }
    }

    private fun sleepBetweenSequentialWrites() {
        try {
            Thread.sleep(500)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            Log.w(TAG, "Delay interrupted", e)
        }
    }

    private fun safeGetWallpaperId(wallpaperManager: WallpaperManager, which: Int): Int {
        return try {
            wallpaperManager.getWallpaperId(which)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read wallpaper id for which=$which", e)
            -1
        }
    }

    private fun didWallpaperIdChange(
        wallpaperManager: WallpaperManager,
        which: Int,
        beforeId: Int
    ): Boolean {
        if (beforeId <= 0) return true // can't verify reliably; assume success
        val afterId = safeGetWallpaperId(wallpaperManager, which)
        return afterId > 0 && afterId != beforeId
    }

    private fun validateFile(file: File) {
        if (!file.exists() || !file.isFile) {
            throw WallpaperApplyException("sourceNotFound", "Image file not found: ${file.name}")
        }
        if (!file.canRead()) {
            throw WallpaperApplyException(
                "permissionDenied",
                "Cannot read image file: ${file.name}",
            )
        }
        if (file.length() == 0L) {
            throw WallpaperApplyException(
                "sourceNotFound",
                "Image file is empty (0 bytes): ${file.name}",
            )
        }
    }
}
