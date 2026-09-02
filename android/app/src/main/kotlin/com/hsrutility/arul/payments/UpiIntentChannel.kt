package com.hsrutility.arul.payments

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

// The app-side half of the Worker's subscriptions/v2/setup UPI_INTENT path.
// listUpiApps returns the installed mandate-capable apps -> package, label and icon bytes for the paywall's own picker.
// launch fires PhonePe's returned intentUrl at exactly the chosen package -> the user lands on its AutoPay sheet.
// The app list is a fixed ALLOWLIST, never an open upi:// scheme query -> PhonePe's docs name the mandate-capable apps.
// A generic upi:// resolver that only does one-time pay would accept the intent and then fail the mandate.
// That is a dead end the picker must never offer.
class UpiIntentChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/upi_intent"
        private const val TAG = "UpiIntentChannel"

        /** Rendered icon edge in px -> small enough to cross the channel freely. */
        private const val ICON_SIZE = 96

        // Mandate-capable UPI apps per PhonePe's Autopay docs -> the order here IS the picker's preference order.
        // Every package must also appear in the manifest <queries> block -> API 30+ hides it from getApplicationInfo.
        // The simulator entry is PhonePe's test app -> sandbox intentUrls use its ppesim:// scheme, so it resolves only there.
        //
        // The HEAD of this list is also the DEFAULT: `_resolvedUpiPackage` falls back to `upiApps.first`
        // for every user who never opens the picker, so re-ordering here re-targets those mandates too.
        // Owner's order (NOT market share -> PhonePe moves 49% of UPI volume and is our own PSP).
        // Decouple display order from the default by giving `_resolvedUpiPackage` its own constant.
        private val MANDATE_APPS = listOf(
            "net.one97.paytm",
            "com.phonepe.app",
            "com.google.android.apps.nbu.paisa.user",
            "in.org.npci.upiapp",
            "com.dreamplug.androidapp",
            "in.amazon.mShop.android.shopping",
            "money.super.payments",
            "com.phonepe.simulator",
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listUpiApps" -> result.success(listUpiApps())

            "launch" -> {
                val url = call.argument<String>("url")
                val pkg = call.argument<String>("package")
                if (url.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "url is required", null)
                    return
                }
                result.success(launch(url, pkg))
            }

            else -> result.notImplemented()
        }
    }

    private fun listUpiApps(): List<Map<String, Any?>> {
        val pm = activity.packageManager
        val apps = mutableListOf<Map<String, Any?>>()
        for (pkg in MANDATE_APPS) {
            val info = try {
                pm.getApplicationInfo(pkg, 0)
            } catch (e: PackageManager.NameNotFoundException) {
                continue
            } catch (t: Throwable) {
                Log.w(TAG, "getApplicationInfo failed for $pkg", t)
                continue
            }
            apps.add(
                mapOf(
                    "package" to pkg,
                    "label" to pm.getApplicationLabel(info).toString(),
                    "icon" to iconPng(pm, pkg),
                ),
            )
        }
        return apps
    }

    /** App icon as PNG bytes, or null -> the picker falls back to a glyph. */
    private fun iconPng(pm: PackageManager, pkg: String): ByteArray? = try {
        drawableToPng(pm.getApplicationIcon(pkg))
    } catch (t: Throwable) {
        null
    }

    private fun drawableToPng(drawable: Drawable): ByteArray? = try {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, ICON_SIZE, ICON_SIZE, true)
        } else {
            // AdaptiveIconDrawable and friends have no backing bitmap -> render one.
            val b = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(b)
            drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
            drawable.draw(canvas)
            b
        }
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
    } catch (t: Throwable) {
        Log.w(TAG, "icon render failed", t)
        null
    }

    private fun launch(url: String, pkg: String?): Boolean = try {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        if (!pkg.isNullOrBlank()) intent.setPackage(pkg)
        activity.startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        // The chosen app cannot take this intent -> uninstalled between list and tap, or a scheme it does not register.
        // False -> Dart shows a clean error and abandons the claimed setup, and nothing has been authorized.
        Log.w(TAG, "No activity for UPI intent (pkg=$pkg)")
        false
    } catch (t: Throwable) {
        Log.w(TAG, "UPI intent launch failed", t)
        false
    }
}
