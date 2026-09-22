package com.hsrutility.arul.auth

import android.app.Activity
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Google's OWN dialog for a phone whose Play services is too old, disabled or missing to sign in with.
// On Android 13 and below Credential Manager runs THROUGH Play services: androidx.credentials asks
// isGooglePlayServicesAvailable(context, MIN_GMS_APK_VERSION) and, below it, throws
// GetCredentialProviderConfigurationException -> the plugin's `providerConfigurationError`.
// The wall's one line ("Tap again") can never work there, and the wall may not grow a sentence or a
// link -> the repair has to be Google's dialog, never copy of ours.
// The check MUST use Credential Manager's minimum, not the default one: play-services-base accepts a
// far older Play services than sign-in does, and would call a broken phone healthy.
// The documented order: isGooglePlayServicesAvailable -> isUserResolvableError -> the error dialog,
// which sends the person to the Play Store (out of date / missing) or to Settings (disabled).
// Contract the Dart caller is built against: ensureAvailable -> one of three strings.
// "available" means Play services can sign in -> nothing was shown, the failure was something else.
// "shown" means Google's dialog is on screen -> the person's way back in is THEIR return to the app.
// "unresolved" means no dialog can fix this phone -> the caller changes nothing.
// A healthy phone NEVER sees UI from this: SUCCESS returns before any dialog call is made.
class PlayServicesChannel(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/play_services"

        // androidx.credentials.playservices.CredentialProviderPlayServicesImpl.MIN_GMS_APK_VERSION,
        // read from credentials-play-services-auth 1.6.0 -> re-read it when google_sign_in_android
        // moves to a newer androidx.credentials.
        private const val MIN_GMS_APK_VERSION = 230815045

        private const val REQUEST_RESOLVE = 0x5041 // "PA" -> unique among this activity's requests
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensureAvailable" -> ensureAvailable(result)
            else -> result.notImplemented()
        }
    }

    private fun ensureAvailable(result: MethodChannel.Result) {
        val availability = GoogleApiAvailability.getInstance()
        val code = availability.isGooglePlayServicesAvailable(activity, MIN_GMS_APK_VERSION)
        if (code == ConnectionResult.SUCCESS) {
            result.success("available")
            return
        }
        if (!availability.isUserResolvableError(code) || activity.isFinishing) {
            result.success("unresolved")
            return
        }
        val shown = availability.showErrorDialogFragment(activity, code, REQUEST_RESOLVE)
        result.success(if (shown) "shown" else "unresolved")
    }
}
