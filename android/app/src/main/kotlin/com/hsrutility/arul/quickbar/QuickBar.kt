package com.hsrutility.arul.quickbar

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.util.Log
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.hsrutility.arul.MainActivity
import com.hsrutility.arul.R

/**
 * The always-on Quick Access bar (docs/notifications.md §Quick Access bar). Plain ongoing post, no
 * foreground service: on Android 14+ both are swipeable, and only a service needs Play's FGS review.
 */
object QuickBar {
    private const val TAG = "ArulQuickBar"

    const val CHANNEL_ID = "arul_quick_access_v1"

    /** Clear of the plugin's local posts (3000+) and FCM's tag-keyed campaigns (id 0). */
    private const val NOTIFICATION_ID = 4000

    const val ACTION_DISMISSED = "com.hsrutility.arul.quickbar.DISMISSED"
    private const val ACTION_OPEN_TAB = "com.hsrutility.arul.quickbar.OPEN_TAB"
    private const val EXTRA_TAB = "quick_bar_tab"

    @Volatile
    private var pendingTab: String? = null

    // Mirrored from Dart on every launch -> the boot and dismiss paths run with no Flutter alive.
    private const val PREFS = "arul.quick_bar"
    private const val KEY_ON = "on"
    private const val KEY_CHANNEL_NAME = "channel_name"
    private const val KEY_WALLPAPERS = "label_wallpapers"
    private const val KEY_RINGTONES = "label_ringtones"
    private const val KEY_STATUS = "label_status"

    private const val PILL_PADDING_DP = 8f
    private const val MIN_LABEL_DP = 8.5f

    /** Lower than collapsed: expanded has only the word under its icon, and Tamil needs 8.25dp at 320dp. */
    private const val MIN_EXPANDED_LABEL_DP = 8f

    private val ICON_LABEL_IDS = listOf(
        R.id.quick_bar_wallpapers_icon to R.id.quick_bar_wallpapers_label,
        R.id.quick_bar_ringtones_icon to R.id.quick_bar_ringtones_label,
        R.id.quick_bar_status_icon to R.id.quick_bar_status_label,
    )

    data class Labels(
        val channelName: String,
        val wallpapers: String,
        val ringtones: String,
        val status: String,
    )

    fun sync(context: Context, on: Boolean, labels: Labels) {
        prefs(context).edit()
            .putBoolean(KEY_ON, on)
            .putString(KEY_CHANNEL_NAME, labels.channelName)
            .putString(KEY_WALLPAPERS, labels.wallpapers)
            .putString(KEY_RINGTONES, labels.ringtones)
            .putString(KEY_STATUS, labels.status)
            .apply()
        if (on) post(context) else cancel(context)
    }

    /** Never throws: the receiver calls it at boot, and a bar is never worth a crash. */
    fun post(context: Context) {
        try {
            val prefs = prefs(context)
            if (!prefs.getBoolean(KEY_ON, false)) return
            fun label(key: String, fallback: String) =
                prefs.getString(key, null)?.takeUnless { it.isBlank() } ?: fallback
            val labels = Labels(
                channelName = label(KEY_CHANNEL_NAME, "Quick Access Bar"),
                wallpapers = label(KEY_WALLPAPERS, "Wallpaper"),
                ringtones = label(KEY_RINGTONES, "Ringtone"),
                status = label(KEY_STATUS, "Status"),
            )
            val manager = NotificationManagerCompat.from(context)
            if (!manager.areNotificationsEnabled()) return
            ensureChannel(context, labels.channelName)
            manager.notify(NOTIFICATION_ID, build(context, labels))
        } catch (e: SecurityException) {
            Log.i(TAG, "bar not posted: POST_NOTIFICATIONS not granted")
        } catch (e: Exception) {
            Log.e(TAG, "bar not posted", e)
        }
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    /** What the Settings toggle needs to know before it can promise a visible bar. */
    fun status(context: Context): Map<String, Boolean> = mapOf(
        "permitted" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
        "channelBlocked" to channelBlocked(context),
    )

    fun channelBlocked(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val channel = context.getSystemService(NotificationManager::class.java)
            ?.getNotificationChannel(CHANNEL_ID) ?: return false
        return channel.importance == NotificationManager.IMPORTANCE_NONE
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** LOW: silent and no heads-up; MIN would drop the status-bar icon and sink below the fold. */
    private fun ensureChannel(context: Context, name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            },
        )
    }

    private fun build(context: Context, labels: Labels): Notification {
        val names = listOf(labels.wallpapers, labels.ringtones, labels.status)
        val collapsed = buttons(context, R.layout.quick_bar_collapsed, labels)
            .apply { fitCollapsed(context, this, names) }
        val expanded = buttons(context, R.layout.quick_bar_expanded, labels)
            .apply { fitExpanded(context, this, names) }
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(context, R.color.notification_accent))
            // Read by TalkBack and by any surface that drops custom views.
            .setContentTitle(names.joinToString(" · "))
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(collapsed)
            .setCustomBigContentView(expanded)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setLocalOnly(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(openApp(context))
            .setDeleteIntent(dismissed(context))
            .build()
            .apply { flags = flags or Notification.FLAG_NO_CLEAR }
    }

    private fun buttons(context: Context, layout: Int, labels: Labels) =
        RemoteViews(context.packageName, layout).apply {
            setTextViewText(R.id.quick_bar_wallpapers_label, labels.wallpapers)
            setTextViewText(R.id.quick_bar_ringtones_label, labels.ringtones)
            setTextViewText(R.id.quick_bar_status_label, labels.status)
            setContentDescription(R.id.quick_bar_wallpapers, labels.wallpapers)
            setContentDescription(R.id.quick_bar_ringtones, labels.ringtones)
            setContentDescription(R.id.quick_bar_status, labels.status)
            setOnClickPendingIntent(R.id.quick_bar_wallpapers, openTab(context, "wallpapers", 4101))
            setOnClickPendingIntent(R.id.quick_bar_ringtones, openTab(context, "ringtones", 4102))
            setOnClickPendingIntent(R.id.quick_bar_status, openTab(context, "status", 4103))
        }

    /**
     * Collapsed buttons get ~63dp each on a 360dp phone — half the audience — with font scales up to
     * 1.5 common, so the richest form that fits wins: icon + label, a label shrunk to fit, then the
     * icon alone. Measured here because RemoteViews cannot react to an ellipsis; a font or size
     * change shows at the next post.
     */
    private fun fitCollapsed(context: Context, views: RemoteViews, names: List<String>) {
        val button = buttonDp(context, names.size, chromeDp = 156f)
        val label = labelDp(context, names, sp = 10f)
        val withIcon = label + PILL_PADDING_DP + 19f <= button
        val shrunk = if (withIcon) null else shrinkPx(context, label, 10f, button - PILL_PADDING_DP, MIN_LABEL_DP)
        val showLabel = withIcon || shrunk != null
        for ((icon, text) in ICON_LABEL_IDS) {
            views.setViewVisibility(icon, if (withIcon || !showLabel) View.VISIBLE else View.GONE)
            views.setViewVisibility(text, if (showLabel) View.VISIBLE else View.GONE)
            if (shrunk != null) views.setTextViewTextSize(text, TypedValue.COMPLEX_UNIT_PX, shrunk)
        }
    }

    /** Expanded stacks icon over label, so only the label's width matters. */
    private fun fitExpanded(context: Context, views: RemoteViews, names: List<String>) {
        val button = buttonDp(context, names.size, chromeDp = 116f)
        val label = labelDp(context, names, sp = 11f)
        if (label + 6f <= button) return
        val shrunk = shrinkPx(context, label, 11f, button - 6f, MIN_EXPANDED_LABEL_DP)
            ?: (MIN_EXPANDED_LABEL_DP * context.resources.displayMetrics.density)
        for ((_, text) in ICON_LABEL_IDS) views.setTextViewTextSize(text, TypedValue.COMPLEX_UNIT_PX, shrunk)
    }

    /** The shade's card, the header column and (collapsed) the expander, measured on device; 4dp gaps. */
    private fun buttonDp(context: Context, count: Int, chromeDp: Float): Float =
        (context.resources.configuration.smallestScreenWidthDp - chromeDp - 8f * (count - 1)) / count

    private fun labelDp(context: Context, names: List<String>, sp: Float): Float {
        val metrics = context.resources.displayMetrics
        val paint = Paint().apply {
            isAntiAlias = true
            typeface = Typeface.DEFAULT_BOLD
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, metrics)
        }
        // OEM fonts run wider than the default bold this measures with.
        return (names.maxOf { paint.measureText(it) } / metrics.density * 1.08f).coerceAtLeast(1f)
    }

    /** The text size that fits [room], or null below [minDp] — smaller than that stops reading. */
    private fun shrinkPx(context: Context, labelDp: Float, sp: Float, room: Float, minDp: Float): Float? {
        val metrics = context.resources.displayMetrics
        val px = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, metrics) * room / labelDp
        return px.takeIf { it >= minDp * metrics.density }
    }

    /**
     * Parked for Dart rather than sent as a link: in a task Android restored after killing the process,
     * the tap arrives through onNewIntent before Flutter's router exists, and Flutter drops the route.
     * An activity PendingIntent, never a receiver — Android 12+ blocks notification trampolines.
     */
    private fun openTab(context: Context, screen: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(ACTION_OPEN_TAB)
            .putExtra(EXTRA_TAB, screen)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** MainActivity hands every launch and new intent here; Dart takes the tab on start and on resume. */
    fun capture(intent: Intent?) {
        if (intent?.action != ACTION_OPEN_TAB) return
        pendingTab = intent.getStringExtra(EXTRA_TAB)
        intent.removeExtra(EXTRA_TAB)
    }

    fun takePendingTab(): String? = pendingTab.also { pendingTab = null }

    private fun openApp(context: Context): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context,
            4104,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Fires on a swipe or Clear all, never on our own cancel() -> the bar re-posts straight away (owner's call). */
    private fun dismissed(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        4105,
        Intent(context, QuickBarReceiver::class.java).setAction(ACTION_DISMISSED),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
