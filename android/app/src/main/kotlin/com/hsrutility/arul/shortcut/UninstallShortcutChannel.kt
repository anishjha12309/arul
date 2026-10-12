package com.hsrutility.arul.shortcut

import android.app.Activity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart's handle on [UninstallShortcut]. Stateless and activity-scoped -> it needs no disposal. */
class UninstallShortcutChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.hsrutility.arul/uninstall_shortcut"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sync" -> result.success(
                UninstallShortcut.sync(
                    activity.applicationContext,
                    publish = call.argument<Boolean>("publish") ?: false,
                    shortLabel = call.argument<String>("shortLabel").orEmpty(),
                    longLabel = call.argument<String>("longLabel").orEmpty(),
                ),
            )
            "takePendingTap" -> result.success(UninstallShortcut.takePendingTap())
            "openAppInfo" -> result.success(UninstallShortcut.openAppInfo(activity))
            else -> result.notImplemented()
        }
    }
}
