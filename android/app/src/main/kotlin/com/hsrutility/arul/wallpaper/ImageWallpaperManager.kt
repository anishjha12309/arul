package com.hsrutility.arul.wallpaper

import android.app.WallpaperManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import com.hsrutility.arul.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream

// Sets static image wallpapers via WallpaperManager -> it THROWS [WallpaperApplyException], never returns a payload.
// The primary path is setStream(), which is memory-efficient.
// A decoded-bitmap fallback covers lock-sensitive OEMs where the stream path silently no-ops.
// Pre-flight isWallpaperSupported and isSetWallpaperAllowed -> managed and kiosk devices block wallpaper changes.
// "both" writes home then lock SEQUENTIALLY with a short gap -> some OEMs drop the second write issued back-to-back.
// Each of those writes carries the bitmap fallback too.
// Sources are normalized and downscaled first -> that is what avoids OOM on budget SoCs.
class ImageWallpaperManager(private val context: Context) {

    companion object {
        private const val TAG = "ImageWallpaperManager"

        /** Debug-only log -> the BuildConfig.DEBUG gate strips it from a release build. */
        private fun logd(msg: String) {
            if (BuildConfig.DEBUG) Log.d(TAG, msg)
        }
    }

    private val imageNormalizer: ImageNormalizer by lazy {
        ImageNormalizer(context)
    }

    /** Sets [imageFile] on [target] ("home", "lock" or "both"), entirely on Dispatchers.IO. */
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

            logd(
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

            logd("Wallpaper set successfully")
        }

    // Sets an ALREADY-DECODED bitmap on home AND lock, for the live-wallpaper static fallback.
    // A device that cannot run live wallpapers at all gets the clip's own first frame instead of a dead end.
    // Deliberately NOT [setWallpaper]'s path -> the frame arrives decoded and setBitmap is stored by the OS as PNG.
    // Routing it through [ImageNormalizer.normalizeIfNeeded] would add an RGB_565 decode and a JPEG q90 re-encode.
    // Only the centre-crop is shared -> the framing matches a static apply exactly.
    // `visibleCropHint = null` is correct HERE and nowhere else -> the bitmap is already display-aspect.
    // So the OS has no slack to hand the launcher as parallax room.
    // A null hint on a RAW file is forbidden (docs/edge-cases.md) -> that is what framed every subject right of centre.
    // Home and lock in ONE write -> the chooser this stands in for commits which=3, so the fallback matches.
    // setBitmap returns the new wallpaper's id, or ZERO on failure -> that zero is the whole verification.
    // Hence this path needs none of [setWallpaper]'s before/after getWallpaperId diffing.
    // The CALLER owns the bitmap and must recycle it -> this only recycles the cropped copy it makes itself.
    suspend fun setWallpaperFromBitmap(bitmap: Bitmap) =
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

            val cropped = imageNormalizer.cropToDisplayAspect(bitmap)
            logd("Setting bitmap wallpaper: ${cropped.width}x${cropped.height}")

            try {
                val id = wallpaperManager.setBitmap(
                    cropped,
                    null,
                    true,
                    WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK,
                )
                if (id == 0) {
                    throw WallpaperApplyException(
                        "applyFailed",
                        "The system rejected the wallpaper write.",
                    )
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "SecurityException setting bitmap wallpaper", e)
                throw WallpaperApplyException(
                    "permissionDenied",
                    "Permission denied: ${e.message ?: "SET_WALLPAPER required"}",
                )
            } catch (e: OutOfMemoryError) {
                Log.e(TAG, "OOM setting bitmap wallpaper", e)
                throw WallpaperApplyException(
                    "applyFailed",
                    "Image is too large to process. Try a smaller image.",
                )
            } catch (e: WallpaperApplyException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Unexpected error setting bitmap wallpaper", e)
                throw WallpaperApplyException(
                    "applyFailed",
                    "Failed to set wallpaper: ${e.message ?: "Unknown error"}",
                )
            } finally {
                if (cropped !== bitmap && !cropped.isRecycled) cropped.recycle()
            }

            logd("Bitmap wallpaper set successfully")
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
            logd("Lock fallback (restrictiveOem=$restrictiveOem, changed=$lockChanged)")
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
            // visibleCropHint=null -> the system handles cropping; allowBackup is true.
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
        if (beforeId <= 0) return true // cannot verify reliably -> assume success
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
