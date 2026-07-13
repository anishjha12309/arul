package com.hsrapps.arul.wallpaper

import android.os.Build
import java.util.Locale

/**
 * Centralized OEM policy checks for wallpaper target reliability.
 *
 * Some OEM ROMs (Xiaomi/MIUI, Oppo/ColorOS, Vivo/FuntouchOS, Realme) apply
 * extra restrictions that make lock-screen wallpaper targets unreliable for
 * third-party apps, and they control live-wallpaper lock behavior themselves.
 * We use this to fall back to home-only or a bitmap-set retry on those devices.
 *
 * Adopted into the app from the vendored flutter_wallpaper_plus package so the
 * apply logic lives in com.hsrapps.arul with no external plugin dependency.
 */
object OemPolicy {
    private val restrictiveVendors = listOf(
        "xiaomi",
        "redmi",
        "oppo",
        "vivo",
        "realme",
    )

    fun manufacturerRaw(): String = Build.MANUFACTURER.orEmpty()

    fun modelRaw(): String = Build.MODEL.orEmpty()

    private fun manufacturerNormalized(): String =
        manufacturerRaw().lowercase(Locale.US)

    fun isRestrictiveOem(): Boolean {
        val manufacturer = manufacturerNormalized()
        return restrictiveVendors.any { key -> manufacturer.contains(key) }
    }
}
