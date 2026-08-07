package com.hsrutility.arul.wallpaper

import android.os.Build
import java.util.Locale

/**
 * Centralized OEM policy check for wallpaper apply reliability.
 *
 * Some OEM ROMs make the lock-screen wallpaper write silently no-op for
 * third-party apps via setStream. [ImageWallpaperManager] uses this to FORCE
 * the decoded-bitmap retry on those devices (in addition to the wallpaper-id
 * change check, which is the safety net for OEMs not listed here). A false
 * positive only costs a redundant second write, so the list is deliberately
 * broad — it includes OEM families we cannot test on directly.
 *
 * Adopted into the app from the vendored flutter_wallpaper_plus package so the
 * apply logic lives in com.hsrutility.arul with no external plugin dependency.
 */
object OemPolicy {
    private val restrictiveVendors = listOf(
        // MIUI/HyperOS — Poco devices report MANUFACTURER "Xiaomi".
        "xiaomi",
        "redmi",
        // ColorOS family — OxygenOS 12+ is ColorOS-based, so OnePlus gets the
        // same lock-write quirks as Oppo/Realme.
        "oppo",
        "realme",
        "oneplus",
        // Funtouch/OriginOS — iQOO devices report MANUFACTURER "vivo".
        "vivo",
        // Transsion HiOS/XOS/itelOS — heavily skinned budget ROMs (India).
        "tecno",
        "infinix",
        "itel",
    )

    private fun manufacturerNormalized(): String =
        Build.MANUFACTURER.orEmpty().lowercase(Locale.US)

    fun isRestrictiveOem(): Boolean {
        val manufacturer = manufacturerNormalized()
        return restrictiveVendors.any { key -> manufacturer.contains(key) }
    }
}
