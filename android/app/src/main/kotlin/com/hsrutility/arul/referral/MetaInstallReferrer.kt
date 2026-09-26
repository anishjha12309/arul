package com.hsrutility.arul.referral

import android.content.Context
import android.net.Uri
import org.json.JSONObject

// Meta Install Referrer (developers.facebook.com/documentation/app-ads/meta-install-referrer): the
// Facebook, Instagram and FB Lite apps hold this app's last Meta ad touch, view-through and
// later-session clicks included — the installs Play's referrer files as organic.
object MetaInstallReferrer {
    private val AUTHORITIES = listOf(
        "com.facebook.katana.provider.InstallReferrerProvider",
        "com.instagram.contentprovider.InstallReferrerProvider",
        "com.facebook.lite.provider.InstallReferrerProvider",
    )

    // Blocking provider IPC -> call off the main thread. Null = no Meta touch or no Meta app installed.
    // The campaign metadata stays encrypted: only the plain utm_source, is_ct and timestamp are read.
    fun read(context: Context, appId: String): Map<String, Any>? {
        for (authority in AUTHORITIES) {
            if (context.packageManager.resolveContentProvider(authority, 0) == null) continue
            query(context, authority, appId)?.let { return it }
        }
        return null
    }

    private fun query(context: Context, authority: String, appId: String): Map<String, Any>? {
        return try {
            context.contentResolver.query(
                Uri.parse("content://$authority/$appId"),
                arrayOf("install_referrer", "is_ct", "actual_timestamp"),
                null,
                null,
                null,
            )?.use { c ->
                if (!c.moveToFirst()) return null
                val referrer = c.getString(c.getColumnIndexOrThrow("install_referrer"))
                if (referrer.isNullOrBlank()) return null
                mapOf(
                    "utm_source" to utmSource(referrer),
                    "is_ct" to c.getInt(c.getColumnIndexOrThrow("is_ct")),
                    "actual_timestamp" to c.getLong(c.getColumnIndexOrThrow("actual_timestamp")),
                )
            }
        } catch (e: Exception) {
            null
        }
    }

    // Meta documents the value as serialized JSON; a Play-style query string is tolerated too.
    private fun utmSource(referrer: String): String {
        val fromJson = try {
            JSONObject(referrer).optString("utm_source")
        } catch (e: Exception) {
            ""
        }
        if (fromJson.isNotBlank()) return fromJson
        return try {
            Uri.parse("?$referrer").getQueryParameter("utm_source").orEmpty()
        } catch (e: Exception) {
            ""
        }
    }
}
