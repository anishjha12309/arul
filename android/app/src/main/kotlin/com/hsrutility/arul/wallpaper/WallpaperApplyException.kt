package com.hsrutility.arul.wallpaper

// [code] is a STABLE machine code surfaced to Dart as the MethodChannel error code -> the UI maps it to a locale string.
// [message] is the human-readable detail -> never localized here.
class WallpaperApplyException(
    val code: String,
    override val message: String,
) : Exception(message)
