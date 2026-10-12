package com.hsrutility.arul.shortcut

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.hsrutility.arul.MainActivity
import com.hsrutility.arul.R

// The label must stay true: every tap that cannot reach the ₹99 sheet, whose "Uninstall anyway"
// opens App info, lands in App info straight away.
/** The long-press "Uninstall" shortcut (docs/winback-reach.md). */
object UninstallShortcut {
    private const val TAG = "ArulUninstallShortcut"

    const val SHORTCUT_ID = "winback_uninstall"
    const val ACTION = "com.hsrutility.arul.shortcut.UNINSTALL"

    const val TAP_OFFER = "offer"
    const val TAP_APP_INFO = "app_info"

    // Dart takes a parked tap on start and on resume; one still waiting by then goes to App info.
    private const val TAKE_DEADLINE_MS = 15_000L

    // Mirrored from Dart on every sync -> a tap decides with no Flutter alive yet.
    private const val PREFS = "arul.uninstall_shortcut"
    private const val KEY_OFFER_ALLOWED = "offer_allowed"
    private const val KEY_SHORT_LABEL = "short_label"
    private const val KEY_LONG_LABEL = "long_label"

    @Volatile
    private var pendingTap: String? = null

    private val main = Handler(Looper.getMainLooper())
    private var watchdog: Runnable? = null

    // Never disableShortcuts: a disabled pinned copy cannot launch, so its label would lie.
    fun sync(
        context: Context,
        publish: Boolean,
        shortLabel: String,
        longLabel: String,
    ): Map<String, Boolean> {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_OFFER_ALLOWED, publish)
            .putString(KEY_SHORT_LABEL, shortLabel)
            .putString(KEY_LONG_LABEL, longLabel)
            .apply()
        var rateLimited = false
        try {
            if (publish) {
                val current = find(context, ShortcutManagerCompat.FLAG_MATCH_DYNAMIC)
                val same = current != null &&
                    current.shortLabel.toString() == shortLabel &&
                    current.longLabel?.toString() == longLabel
                // pushDynamicShortcut also reports a use, so it runs only when something changed.
                if (!same) {
                    if (ShortcutManagerCompat.isRateLimitingActive(context)) {
                        rateLimited = true
                    } else {
                        val info = build(context, shortLabel, longLabel)
                        ShortcutManagerCompat.pushDynamicShortcut(context, info)
                    }
                }
            } else {
                ShortcutManagerCompat.removeDynamicShortcuts(context, listOf(SHORTCUT_ID))
                // A pinned copy outlives the removal; its words still follow the app's language.
                val pinned = find(context, ShortcutManagerCompat.FLAG_MATCH_PINNED)
                if (pinned != null && pinned.shortLabel.toString() != shortLabel) {
                    val info = build(context, shortLabel, longLabel)
                    ShortcutManagerCompat.updateShortcuts(context, listOf(info))
                }
            }
        } catch (e: IllegalStateException) {
            Log.w(TAG, "sync refused (locked user or rate limit)", e)
            rateLimited = true
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "sync rejected", e)
        }
        return mapOf(
            "published" to (find(context, ShortcutManagerCompat.FLAG_MATCH_DYNAMIC) != null),
            "pinned" to (find(context, ShortcutManagerCompat.FLAG_MATCH_PINNED) != null),
            "rateLimited" to rateLimited,
        )
    }

    /** MainActivity hands every launch and new intent here. */
    fun capture(activity: Activity, intent: Intent?) {
        if (intent?.action != ACTION) return
        try {
            ShortcutManagerCompat.reportShortcutUsed(activity, SHORTCUT_ID)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "usage report refused", e)
        }
        val offerAllowed = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_OFFER_ALLOWED, false)
        cancelWatchdog()
        if (!offerAllowed) {
            // A pinned copy, a signed-out phone, a plan bought since: no ₹99 sheet to open.
            pendingTap = TAP_APP_INFO
            openAppInfo(activity)
            return
        }
        pendingTap = TAP_OFFER
        val app = activity.applicationContext
        val fallback = Runnable {
            if (pendingTap == TAP_OFFER) {
                pendingTap = null
                openAppInfo(app)
            }
        }
        watchdog = fallback
        main.postDelayed(fallback, TAKE_DEADLINE_MS)
    }

    fun takePendingTap(): String? {
        cancelWatchdog()
        return pendingTap.also { pendingTap = null }
    }

    /** Arul's App info page, which holds the phone's own Uninstall button. */
    fun openAppInfo(context: Context): Boolean {
        val details = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        )
        val candidates = listOf(
            details,
            Intent(Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (intent in candidates) {
            if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
                return true
            } catch (e: Exception) {
                Log.w(TAG, "settings intent unresolvable, trying fallback", e)
            }
        }
        return false
    }

    private fun cancelWatchdog() {
        watchdog?.let(main::removeCallbacks)
        watchdog = null
    }

    private fun find(context: Context, flag: Int): ShortcutInfoCompat? =
        ShortcutManagerCompat.getShortcuts(context, flag).firstOrNull { it.id == SHORTCUT_ID }

    // SINGLE_TOP|CLEAR_TOP: a running app takes the tap in onNewIntent and keeps its state.
    private fun build(context: Context, shortLabel: String, longLabel: String) =
        ShortcutInfoCompat.Builder(context, SHORTCUT_ID)
            .setShortLabel(shortLabel)
            .setLongLabel(longLabel)
            .setIcon(IconCompat.createWithResource(context, R.drawable.ic_shortcut_uninstall))
            .setIntent(
                Intent(context, MainActivity::class.java)
                    .setAction(ACTION)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    ),
            )
            .build()
}
