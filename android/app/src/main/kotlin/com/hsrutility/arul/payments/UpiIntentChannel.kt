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

/**
 * Direct UPI-intent mandate flow — the app-side half of the Worker's
 * subscriptions/v2/setup UPI_INTENT path.
 *
 *   listUpiApps → which mandate-capable UPI apps are installed (package, label,
 *                 icon PNG bytes) so the paywall can render its own picker.
 *   launch      → fire the PhonePe-returned intentUrl (upi://mandate?…) as an
 *                 ACTION_VIEW aimed at exactly the chosen package, landing the
 *                 user straight on that app's AutoPay approval sheet.
 *
 * The app list is a fixed allowlist, NOT an open upi:// scheme query: PhonePe's
 * Autopay docs name the mandate-capable apps, and a generic upi:// resolver
 * (some wallet that only does one-time pay) would accept the intent and then
 * fail the mandate — a dead end the picker must never offer.
 */
class UpiIntentChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/upi_intent"
        private const val TAG = "UpiIntentChannel"

        /** Rendered icon edge in px — small enough to cross the channel freely. */
        private const val ICON_SIZE = 96

        /**
         * Mandate-capable UPI apps per PhonePe's Autopay docs (PhonePe, GPay,
         * Paytm, BHIM, CRED, Amazon Pay, SuperMoney). Order here IS the
         * picker's preference order. Every package must also appear in the
         * manifest <queries> block or API 30+ hides it from getApplicationInfo.
         * The simulator entry is PhonePe's test app — sandbox intentUrls use
         * its ppesim:// scheme, so it only ever resolves in sandbox testing.
         */
        private val MANDATE_APPS = listOf(
            "com.phonepe.app",
            "com.google.android.apps.nbu.paisa.user",
            "net.one97.paytm",
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

    /** App icon as PNG bytes, or null — the picker falls back to a glyph. */
    private fun iconPng(pm: PackageManager, pkg: String): ByteArray? = try {
        drawableToPng(pm.getApplicationIcon(pkg))
    } catch (t: Throwable) {
        null
    }

    private fun drawableToPng(drawable: Drawable): ByteArray? = try {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, ICON_SIZE, ICON_SIZE, true)
        } else {
            // AdaptiveIconDrawable and friends have no backing bitmap — render.
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
        // Chosen app can't take this intent (uninstalled between list and tap,
        // or a scheme it doesn't register). False → Dart shows a clean error
        // and abandons the claimed setup; nothing has been authorized.
        Log.w(TAG, "No activity for UPI intent (pkg=$pkg)")
        false
    } catch (t: Throwable) {
        Log.w(TAG, "UPI intent launch failed", t)
        false
    }
}
