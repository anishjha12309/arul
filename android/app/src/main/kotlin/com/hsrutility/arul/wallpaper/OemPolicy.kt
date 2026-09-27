package com.hsrutility.arul.wallpaper

import android.os.Build
import java.util.Locale

// A false positive only costs a redundant second write -> the list is deliberately broad.
// It includes OEM families nobody here can test on directly.
object OemPolicy {
    private val restrictiveVendors = listOf(
        // MIUI/HyperOS -> Poco devices report MANUFACTURER "Xiaomi".
        "xiaomi",
        "redmi",
        // ColorOS family -> OxygenOS 12+ is ColorOS-based, so OnePlus inherits Oppo and Realme's lock-write quirks.
        "oppo",
        "realme",
        "oneplus",
        // Funtouch/OriginOS -> iQOO devices report MANUFACTURER "vivo".
        "vivo",
        // Transsion HiOS/XOS/itelOS -> heavily skinned budget ROMs, common in India.
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
