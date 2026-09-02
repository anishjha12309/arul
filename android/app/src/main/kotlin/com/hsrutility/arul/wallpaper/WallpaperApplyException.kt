package com.hsrutility.arul.wallpaper

// [code] is a STABLE machine code surfaced to Dart as the MethodChannel error code -> the UI maps it to a locale string.
// [message] is the human-readable detail -> never localized here.
// Codes: unsupported · manufacturerRestriction · permissionDenied · sourceNotFound · applyFailed · unknown.
class WallpaperApplyException(
    val code: String,
    override val message: String,
) : Exception(message)
