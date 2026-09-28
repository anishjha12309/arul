package com.hsrutility.arul.payments

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class UpiIntentChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/upi_intent"
        private const val TAG = "UpiIntentChannel"

        /** Rendered icon edge in px -> small enough to cross the channel freely. */
        private const val ICON_SIZE = 96

        // Mandate-capable UPI apps per PhonePe's Autopay docs -> the order here IS the picker's preference order.
        // Every package must also appear in the manifest <queries> block -> API 30+ hides it from getApplicationInfo.
        // The simulator entry is PhonePe's test app -> sandbox intentUrls use its ppesim:// scheme, so it resolves only there.
        // The HEAD of this list is also the DEFAULT: `_resolvedUpiPackage` falls back to `upiApps.first`
        // for every user who never opens the picker, so re-ordering here re-targets those mandates too.
        // Owner's order: PhonePe leads as both the default and the first chip -> it is our own PSP
        // and moves 49% of UPI volume, so its mandate sheet is the one most users already trust.
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

        // Mandate-SHAPED, with no real VPA, payee or amount behind it -> nothing is ever launched at
        // it. Only the shape matters: an app registers upi://mandate separately from upi://pay, and
        // it is that separation the intersection reads.
        private const val MANDATE_PROBE_URL =
            "upi://mandate?pa=probe@upi&pn=Probe&am=1.00&mn=Autopay"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listUpiApps" -> result.success(scanUpiApps())

            // The same offer set with no labels or icons -> cheap enough for the analytics stamp,
            // which must never pay the PNG renders the picker needs.
            "listUpiPackages" -> {
                val pm = activity.packageManager
                result.success(offeredPackages(pm, mandateHandlers(pm)).map { it.first })
            }

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

    /**
     * Both halves of the probe: the apps we OFFER, and the mandate-capable packages we refuse.
     */
    private fun scanUpiApps(): Map<String, Any?> {
        val pm = activity.packageManager
        val handlers = mandateHandlers(pm)
        return mapOf(
            "offered" to offeredUpiApps(pm, handlers),
            // Null handlers = the probe itself failed, so we know nothing about what is out there.
            // An empty list is then the honest answer, never a claim that nothing else is installed.
            "others" to (handlers?.minus(MANDATE_APPS.toSet())?.sorted() ?: emptyList()),
        )
    }

    private fun offeredUpiApps(
        pm: PackageManager,
        handlers: Set<String>?,
    ): List<Map<String, Any?>> = offeredPackages(pm, handlers).map { (pkg, info) ->
        mapOf(
            "package" to pkg,
            "label" to pm.getApplicationLabel(info).toString(),
            "icon" to iconPng(pm, pkg),
        )
    }

    private fun offeredPackages(
        pm: PackageManager,
        handlers: Set<String>?,
    ): List<Pair<String, ApplicationInfo>> {
        val apps = mutableListOf<Pair<String, ApplicationInfo>>()
        for (pkg in MANDATE_APPS) {
            if (handlers != null && pkg !in handlers) {
                Log.i(TAG, "$pkg is installed but resolves no mandate -> not offered")
                continue
            }
            val info = try {
                pm.getApplicationInfo(pkg, 0)
            } catch (e: PackageManager.NameNotFoundException) {
                continue
            } catch (t: Throwable) {
                Log.w(TAG, "getApplicationInfo failed for $pkg", t)
                continue
            }
            apps.add(pkg to info)
        }
        return apps
    }

    /**
     * Packages whose activities answer a mandate-shaped VIEW intent, or null if the query failed.
     *
     * Null and empty mean different things: null keeps every allowlisted app, empty removes them all.
     */
    private fun mandateHandlers(pm: PackageManager): Set<String>? {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(MANDATE_PROBE_URL))
        return try {
            val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                pm.queryIntentActivities(intent, 0)
            }
            resolved.mapNotNull { it.activityInfo?.packageName }.toSet()
        } catch (t: Throwable) {
            Log.w(TAG, "mandate probe failed -> offering the allowlist unfiltered", t)
            null
        }
    }

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
        Log.w(TAG, "No activity for UPI intent (pkg=$pkg)")
        false
    } catch (t: Throwable) {
        Log.w(TAG, "UPI intent launch failed", t)
        false
    }
}
