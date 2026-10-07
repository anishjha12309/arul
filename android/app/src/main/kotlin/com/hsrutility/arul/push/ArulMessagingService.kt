package com.hsrutility.arul.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.RemoteMessage
import com.hsrutility.arul.R
import io.flutter.plugins.firebase.messaging.ContextHolder
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingStore
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.pow

/**
 * Draws every data-only campaign notification itself (docs/push.md §Drawn campaigns).
 */
class ArulMessagingService : FlutterFirebaseMessagingService() {

    companion object {
        private const val TAG = "ArulPush"

        /** Mirrors NotificationService._updatesChannel() in Dart — id, importance and fallback name. */
        private const val FALLBACK_CHANNEL_ID = "arul_updates_v1"
        private const val FALLBACK_CHANNEL_NAME = "Updates from Arul"

        /** Mirrors NotificationService.campaignChannelId. Only Dart creates it, at the user's level. */
        private const val CAMPAIGN_CHANNEL_ID = "arul_campaigns_v1"

        /** The same text colour the CMS preview picks, so the composer and the phone agree. */
        private const val DARK_TEXT = 0xFF1B1B1F.toInt()

        private const val PICTURE_DEADLINE_MS = 5_000L
        private const val PICTURE_MAX_PX = 1024
        private const val PICTURE_MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024
    }

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        val data = remoteMessage.data
        if (remoteMessage.notification != null || data["campaign_id"] == null) {
            super.onMessageReceived(remoteMessage)
            return
        }
        try {
            post(remoteMessage, data)
        } catch (e: Exception) {
            // Never crash the messaging service: a broken card costs one notification, a crash here
            // costs every later message until the process restarts.
            Log.e(TAG, "campaign ${data["campaign_id"]} not posted", e)
        }
    }

    private fun post(message: RemoteMessage, data: Map<String, String>) {
        if (ContextHolder.getApplicationContext() == null) {
            ContextHolder.setApplicationContext(applicationContext)
        }
        val campaignId = data["campaign_id"].orEmpty()
        val tag = data["tag"] ?: campaignId
        val channelId = channelFor(data["channel_id"])
        val headsUp = channelId == CAMPAIGN_CHANNEL_ID
        val title = data["title"].orEmpty()
        val body = data["body"].orEmpty()
        val background = parseColor(data["color"])

        ensureChannel(channelId)
        val picture = data["image"]?.let { downloadPicture(it) }

        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(this, R.color.notification_accent))
            // Also set on the builder: the lock screen's redacted view, accessibility and any surface
            // that drops custom views still read these.
            .setContentTitle(title)
            .setContentText(body)
            // Android 7.1 and lower have no channels: a heads-up there takes high priority AND a sound.
            .setPriority(
                if (headsUp) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT,
            )
            .setAutoCancel(true)
            .setContentIntent(tapIntent(message, data, campaignId))
        if (headsUp && Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setDefaults(NotificationCompat.DEFAULT_SOUND)
        }
        if (data["visibility"] == "public") {
            builder.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        }

        if (background != null) {
            val ink = textColorOn(background)
            builder
                .setStyle(NotificationCompat.DecoratedCustomViewStyle())
                .setCustomContentView(contentView(R.layout.push_colored_collapsed, background, ink, title, body, null))
                .setCustomBigContentView(contentView(R.layout.push_colored_expanded, background, ink, title, body, picture))
        } else if (picture != null) {
            // FCM's own picture layout, which the CMS preview draws: a thumbnail beside the text
            // collapsed, the whole picture expanded.
            builder
                .setLargeIcon(picture)
                .setStyle(
                    NotificationCompat.BigPictureStyle()
                        .bigPicture(picture)
                        .bigLargeIcon(null as Bitmap?),
                )
        } else {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(body))
        }

        val manager = NotificationManagerCompat.from(this)
        if (!manager.areNotificationsEnabled()) {
            Log.i(TAG, "campaign $campaignId dropped: notifications are off for Arul")
            return
        }
        FlutterFirebaseMessagingStore.getInstance().storeFirebaseMessage(message)
        try {
            manager.notify(tag, 0, builder.build())
            Log.i(
                TAG,
                "posted campaign=$campaignId channel=$channelId " +
                    "colour=${background != null} picture=${picture != null}",
            )
        } catch (e: SecurityException) {
            Log.i(TAG, "campaign $campaignId dropped: POST_NOTIFICATIONS not granted")
        }
    }

    private fun contentView(
        layout: Int,
        background: Int,
        ink: Int,
        title: String,
        body: String,
        picture: Bitmap?,
    ): RemoteViews = RemoteViews(packageName, layout).apply {
        setInt(R.id.push_root, "setBackgroundColor", background)
        setTextViewText(R.id.push_title, title)
        setTextColor(R.id.push_title, ink)
        setTextViewText(R.id.push_body, body)
        setTextColor(R.id.push_body, ink)
        if (layout == R.layout.push_colored_expanded) {
            if (picture != null) {
                setImageViewBitmap(R.id.push_picture, picture)
                setViewVisibility(R.id.push_picture, View.VISIBLE)
            } else {
                setViewVisibility(R.id.push_picture, View.GONE)
            }
        }
    }

    /**
     * The same launch intent FCM builds for a notification-message tap: the launcher activity with
     * CLEAR_TOP, the data keys as extras and the message id the plugin keys its lookup on. An
     * activity PendingIntent, never a receiver or service — Android 12+ blocks notification trampolines.
     */
    private fun tapIntent(message: RemoteMessage, data: Map<String, String>, campaignId: String): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        for ((key, value) in data) launch.putExtra(key, value)
        message.messageId?.let { launch.putExtra("google.message_id", it) }
        message.from?.let { launch.putExtra("from", it) }
        return PendingIntent.getActivity(
            this,
            campaignId.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * The campaign channel only where Dart created it, else the first channel: a phone that blocked
     * campaigns before the split must never be handed a fresh, unblocked channel from here.
     */
    private fun channelFor(requested: String?): String {
        if (requested != CAMPAIGN_CHANNEL_ID) return requested ?: FALLBACK_CHANNEL_ID
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return CAMPAIGN_CHANNEL_ID
        val manager = getSystemService(NotificationManager::class.java)
        val exists = manager?.getNotificationChannel(CAMPAIGN_CHANNEL_ID) != null
        return if (exists) CAMPAIGN_CHANNEL_ID else FALLBACK_CHANNEL_ID
    }

    /** Dart creates the channel at every launch; this covers only a phone where that never finished. */
    private fun ensureChannel(channelId: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (channelId == CAMPAIGN_CHANNEL_ID) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(channelId) != null) return
        manager.createNotificationChannel(
            NotificationChannel(channelId, FALLBACK_CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    /** `#rrggbb` only — the Worker's check constraint guarantees it; anything else reads as no colour. */
    private fun parseColor(raw: String?): Int? {
        if (raw == null || !Regex("^#[0-9a-fA-F]{6}$").matches(raw)) return null
        return Color.parseColor(raw)
    }

    /**
     * White when white text reaches a WCAG contrast ratio of 3.0 on the colour, else near-black.
     * The CMS preview runs the identical formula (composerJs `inkOn`) — change both together.
     */
    private fun textColorOn(background: Int): Int {
        fun channel(v: Int): Double {
            val c = v / 255.0
            return if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
        }
        val luminance = 0.2126 * channel(Color.red(background)) +
            0.7152 * channel(Color.green(background)) +
            0.0722 * channel(Color.blue(background))
        return if (1.05 / (luminance + 0.05) >= 3.0) Color.WHITE else DARK_TEXT
    }

    /**
     * The campaign picture, or null. Bounded by ONE wall-clock deadline across connect and read:
     * onMessageReceived has a short execution window, and a picture is never worth the notification.
     */
    private fun downloadPicture(url: String): Bitmap? {
        val deadline = SystemClock.elapsedRealtime() + PICTURE_DEADLINE_MS
        var connection: HttpURLConnection? = null
        return try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = PICTURE_DEADLINE_MS.toInt()
                readTimeout = PICTURE_DEADLINE_MS.toInt()
            }
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return null
            val bytes = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    if (SystemClock.elapsedRealtime() > deadline) return null
                    val n = input.read(buffer)
                    if (n < 0) break
                    bytes.write(buffer, 0, n)
                    if (bytes.size() > PICTURE_MAX_DOWNLOAD_BYTES) return null
                }
            }
            decodeSampled(bytes.toByteArray())
        } catch (e: Exception) {
            Log.i(TAG, "campaign picture skipped: ${e.javaClass.simpleName}")
            null
        } finally {
            connection?.disconnect()
        }
    }

    /** Power-of-two sampling down to <= 1024 px on the long side — the system strips oversized custom views. */
    private fun decodeSampled(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / sample > PICTURE_MAX_PX || bounds.outHeight / sample > PICTURE_MAX_PX) {
            sample *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }
}
