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
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

// The app-side half of the Worker's subscriptions/v2/setup UPI_INTENT path.
// listUpiApps answers with BOTH halves of the probe: `offered`, the installed mandate-capable apps on our
// allowlist -> package, label and icon bytes for the paywall's own picker; and `others`, the packages that
// answer a mandate intent while the allowlist drops them. `others` is REPORTED, never offered -> it is the
// only way to tell "this phone cannot pay" apart from "this phone has an app we refuse to show".
// launch fires PhonePe's returned intentUrl at exactly the chosen package -> the user lands on its AutoPay sheet.
//
// TWO gates, and an app must pass BOTH.
// 1. A fixed ALLOWLIST, never an open upi:// scheme query -> PhonePe's docs name the mandate-capable apps.
//    An open query offers one-time-pay wallets that ACCEPT the intent and then fail the mandate.
// 2. The device's own resolver, against a mandate-shaped URL. An allowlisted app on a build that
//    cannot take a mandate is the same dead end by another route, and Android already knows:
//    Mobikwik resolves upi://pay and NOT upi://mandate, and Paytm answers the two with DIFFERENT
//    activities. Costs no network call and no permission -> the <queries> upi scheme filter that
//    makes it work is already in the manifest.
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
        // Owner's order: PhonePe leads as both the default and the first chip -> it is our own PSP
        // and moves 49% of UPI volume, so its mandate sheet is the one most users already trust.
        // Decouple display order from the default by giving `_resolvedUpiPackage` its own constant.
        // This IS PhonePe's published mandate-supported set, in full: PhonePe, BHIM, GPay, Paytm,
        // CRED, Amazon Pay and SuperMoney (Autopay integration-steps names the seven; the setup
        // API's iOS `targetApp` enum is the same seven). Android takes a package name, which those
        // pages do not print -> each one below is the id on that vendor's own Play listing.
        // The last three were pulled once — 181 recorded mandate attempts between them, ZERO
        // completions — and RESTORED on the owner's call. They sit at the TAIL on purpose: the
        // picker gains them without moving the default or the four ranked below, so a phone whose
        // only UPI app is CRED can now pay at all. They are the ones to watch, and zero completions
        // on a meaningful n is the same condition that pulled them before.
        // Ranked by mandates actually SET UP, not by market share: 405 PhonePe · 132 GPay · 37 Paytm
        // · 1 BHIM. GPay sits second because four times as many people finish a mandate in it as in
        // Paytm, whatever the install base says.
        //
        // Paytm was moved to second on 11 Sep 2026 and REVERTED the same day, unshipped. The case
        // was completion RATE per chooser — Paytm 37/351 = 10.5% against GPay's 132/1560 = 8.5% —
        // and that rate is SELF-SELECTED: it measures people who deliberately scrolled past the top
        // two to pick Paytm, i.e. the most determined payers on the list. Promote it and the
        // population landing on it changes, so the rate it was promoted for is the first thing the
        // promotion destroys. Any future reorder needs a real split test, never an observational
        // rate off a list position the app itself chose.
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
     *
     * `others` exists because "no UPI app" and "no UPI app ON OUR LIST" are not the same fact, and
     * only the first justifies a dead CTA. The upi-scheme <intent> in <queries> already makes every
     * mandate handler visible to the resolver, so naming the ones the allowlist drops costs one set
     * subtraction and no permission. Reported, never offered: a package still earns the picker with
     * one real penny drop, never the resolver alone.
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
    ): List<Map<String, Any?>> {
        val apps = mutableListOf<Map<String, Any?>>()
        for (pkg in MANDATE_APPS) {
            // Null = the probe itself failed -> fall back to the allowlist alone. An empty picker
            // would send someone with PhonePe installed to the install prompt, which is worse than
            // offering an app that might not finish.
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
