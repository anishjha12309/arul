package com.hsrutility.arul.quickbar

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart's handle on [QuickBar]. Stateless and activity-scoped -> it needs no disposal. */
class QuickBarChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.hsrutility.arul/quick_bar"
        private const val TAG = "QuickBarChannel"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sync" -> {
                val labels = QuickBar.Labels(
                    channelName = call.argument<String>("channelName").orEmpty(),
                    wallpapers = call.argument<String>("wallpapers").orEmpty(),
                    ringtones = call.argument<String>("ringtones").orEmpty(),
                    status = call.argument<String>("status").orEmpty(),
                )
                QuickBar.sync(
                    activity.applicationContext,
                    on = call.argument<Boolean>("on") ?: false,
                    labels = labels,
                )
                result.success(QuickBar.status(activity.applicationContext))
            }
            "status" -> result.success(QuickBar.status(activity.applicationContext))
            "takePendingTab" -> result.success(QuickBar.takePendingTab())
            "openSettings" -> {
                openSettings()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The bar's own channel when only it is blocked, else the app's notification screen. */
    private fun openSettings() {
        val candidates = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (QuickBar.channelBlocked(activity)) {
                candidates.add(
                    Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        .putExtra(Settings.EXTRA_CHANNEL_ID, QuickBar.CHANNEL_ID),
                )
            }
            candidates.add(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName),
            )
        }
        candidates.add(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${activity.packageName}")),
        )
        for (intent in candidates) {
            try {
                activity.startActivity(intent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "settings intent unresolvable, trying fallback", e)
            }
        }
    }
}
