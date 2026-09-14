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
 * Draws a COLOURED campaign notification itself (docs/push.md §Coloured campaigns).
 *
 * FCM's notification `color` tints the small icon only, so a card background needs the app to post
 * the notification. The Worker sends a coloured campaign as a DATA-ONLY message to builds >= 76; every
 * other campaign stays a notification message that Play services posts without this class running.
 *
 * WHY THIS SUBCLASSES THE PLUGIN'S SERVICE, read off firebase_messaging 16.6.0's Android source:
 *  (a) Messages reach the plugin through `FlutterFirebaseMessagingReceiver` (the raw c2dm broadcast)
 *      — its `FlutterFirebaseMessagingService.onMessageReceived` is deliberately empty. The receiver
 *      still runs for every message after this change, so nothing Dart sees moves. It starts no
 *      isolate because no `onBackgroundMessage` is registered.
 *  (b) A tap is rebuilt from the launch intent's `google.message_id`, looked up in the receiver's
 *      in-memory map or in `FlutterFirebaseMessagingStore` — and the receiver stores ONLY messages
 *      with a notification block. So this class stores the data-only message itself and puts the
 *      message id on the tap intent: `getInitialMessage()` (killed app) and `onMessageOpenedApp`
 *      (backgrounded app) then return it exactly as they return a plain campaign, and
 *      push_open_handler.dart runs unchanged — `/me/push-opened` and GA4 `push_opened` included.
 *  (c) Token refresh reaches Dart through that same service's `onNewToken`. Subclassing inherits it.
 * Only ONE service may own MESSAGING_EVENT, so the manifest removes the plugin's declaration and
 * registers this one; the alternative (a priority race between two services) is not documented
 * behaviour to rely on.
 *
 * WHAT IT DOES NOT CARRY: FCM's automatic `notification_receive` / `notification_open` Analytics
 * events exist only for notification messages. The CMS numbers and the app's own `push_opened` are
 * unaffected.
 */
class ArulMessagingService : FlutterFirebaseMessagingService() {

    companion object {
        private const val TAG = "ArulPush"

        /** Mirrors NotificationService._updatesChannel() in Dart — id, importance and fallback name. */
        private const val FALLBACK_CHANNEL_ID = "arul_updates_v1"
        private const val FALLBACK_CHANNEL_NAME = "Updates from Arul"

        /** The same text colour the CMS preview picks, so the composer and the phone agree. */
        private const val DARK_TEXT = 0xFF1B1B1F.toInt()

        private const val PICTURE_DEADLINE_MS = 5_000L
        private const val PICTURE_MAX_PX = 1024
        private const val PICTURE_MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024
    }

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        val data = remoteMessage.data
        if (remoteMessage.notification != null || data["color"] == null) {
            super.onMessageReceived(remoteMessage)
            return
        }
        try {
            post(remoteMessage, data)
        } catch (e: Exception) {
            // Never crash the messaging service: a broken card costs one notification, a crash here
            // costs every later message until the process restarts.
            Log.e(TAG, "coloured campaign ${data["campaign_id"]} not posted", e)
        }
    }

    private fun post(message: RemoteMessage, data: Map<String, String>) {
        if (ContextHolder.getApplicationContext() == null) {
            ContextHolder.setApplicationContext(applicationContext)
        }
        val campaignId = data["campaign_id"].orEmpty()
        val tag = data["tag"] ?: campaignId
        val channelId = data["channel_id"] ?: FALLBACK_CHANNEL_ID
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
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(tapIntent(message, data, campaignId))

        if (background != null) {
            val ink = textColorOn(background)
            builder
                .setStyle(NotificationCompat.DecoratedCustomViewStyle())
                .setCustomContentView(contentView(R.layout.push_colored_collapsed, background, ink, title, body, null))
                .setCustomBigContentView(contentView(R.layout.push_colored_expanded, background, ink, title, body, picture))
        } else if (picture != null) {
            // A colour this build cannot read still gets a notification, just not a coloured one.
            builder.setStyle(NotificationCompat.BigPictureStyle().bigPicture(picture))
        }

        val manager = NotificationManagerCompat.from(this)
        if (!manager.areNotificationsEnabled()) {
            Log.i(TAG, "coloured campaign $campaignId dropped: notifications are off for Arul")
            return
        }
        // Stored BEFORE it can be tapped: getInitialMessage() on a killed app reads nothing else.
        FlutterFirebaseMessagingStore.getInstance().storeFirebaseMessage(message)
        try {
            manager.notify(tag, 0, builder.build())
            Log.i(TAG, "posted coloured campaign=$campaignId picture=${picture != null}")
        } catch (e: SecurityException) {
            Log.i(TAG, "coloured campaign $campaignId dropped: POST_NOTIFICATIONS not granted")
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

    /** Dart creates the channel at every launch; this covers only a phone where that never finished. */
    private fun ensureChannel(channelId: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
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
