package com.hsrutility.arul.quickbar

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Brings the bar back after a reboot, an app update or a swipe; QuickBar.post checks it is still on. */
class QuickBarReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            QuickBar.ACTION_DISMISSED,
            -> QuickBar.post(context)
        }
    }
}
