package com.hsrutility.arul.auth

import android.app.Activity
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Google's OWN dialog for a phone whose Play services is too old, disabled or missing to sign in with.
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
