package com.hsrapps.arul.wallpaper

/**
 * Thrown by the native apply layer on failure. [code] is a stable machine code
 * surfaced to Dart over the MethodChannel (as the error code) so the UI can map
 * it to a localized message; [message] is the human-readable detail.
 *
 * Codes: unsupported · manufacturerRestriction · permissionDenied ·
 *        sourceNotFound · applyFailed · unknown
 */
class WallpaperApplyException(
    val code: String,
    override val message: String,
) : Exception(message)
