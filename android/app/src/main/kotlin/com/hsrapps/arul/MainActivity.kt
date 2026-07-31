package com.hsrapps.arul

import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import com.hsrapps.arul.feedvideo.FeedVideoPlugin
import com.hsrapps.arul.feedvideo.VideoThumbnailChannel
import com.hsrapps.arul.share.DirectShareChannel
import com.hsrapps.arul.share.ShareWatermarkChannel
import com.hsrapps.arul.wallpaper.WallpaperApplyChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity, not FlutterActivity: the PhonePe Payment SDK requires it,
// and switching later would mean re-testing the whole activity lifecycle. Costs nothing now.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        // Ringtone set channel (ported from the reference app's ringtone block).
        private const val RINGTONE_CHANNEL = "com.hsrapps.arul/ringtone_set"

        // Exposes isPlayInstall() to Dart — see that function, and the QA-tools
        // gate in the reminders screen.
        private const val BUILD_INFO_CHANNEL = "com.hsrapps.arul/build_info"
    }

    private var wallpaperApplyChannel: WallpaperApplyChannel? = null
    private var feedVideoPlugin: FeedVideoPlugin? = null
    private var videoThumbnailChannel: VideoThumbnailChannel? = null
    private var shareWatermarkChannel: ShareWatermarkChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Anti-piracy FLAG_SECURE (blocks screenshots + screen recording, blanks the
        // recents thumbnail) applies ONLY to the Play-delivered build. An AAB reaches
        // a device solely through Google Play, so "installed by com.android.vending"
        // is the runtime proxy for "this is the shipped AAB" — there is no BuildConfig
        // signal that distinguishes an APK from an AAB (both are the `release` type).
        // Debug and sideloaded release APKs (local test builds) stay visible so
        // screenshots for the Play listing still work. Set here (not the manifest) so
        // it re-applies on every activity recreate — e.g. the Android 12+
        // wallpaper-apply recolor restart. The active setFlags call keeps
        // release-flag-secure-guard.js (which gates the .aab) satisfied.
        if (isPlayInstall()) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        }
    }

    /**
     * True only when this build was delivered by Google Play (the uploaded AAB).
     * Fails CLOSED (treats the app as the shipped build → screenshots blocked) if the
     * installer can't be resolved, so the published app is never left unprotected.
     *
     * This is the app's ONE definition of "this is the artifact Play ships", and it now
     * has two consumers: FLAG_SECURE above, and the reminders screen's QA tools, which
     * are meant to work in a sideloaded RELEASE apk but not in the store build. Keeping
     * them on one predicate is what stops the two from ever disagreeing — a build where
     * screenshots are blocked but the debug tools are showing would be nonsense.
     */
    private fun isPlayInstall(): Boolean {
        return try {
            val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                packageManager.getInstallSourceInfo(packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                packageManager.getInstallerPackageName(packageName)
            }
            installer == "com.android.vending"
        } catch (e: Exception) {
            true
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // In-feed live previews — native Media3 ExoPlayer texture pool. The Dart
        // VideoPreloadController drives a small reuse pool of these players, each
        // rendering into a Flutter Texture via a SurfaceProducer. A live wallpaper
        // that has been APPLIED runs in its own WallpaperService (see wallpaper/),
        // which this plugin does not touch.
        feedVideoPlugin = FeedVideoPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        )

        // Wallpaper apply (static + live).
        val applyChannel = WallpaperApplyChannel(applicationContext)
        wallpaperApplyChannel = applyChannel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WallpaperApplyChannel.CHANNEL,
        ).setMethodCallHandler(applyChannel)

        // Grid fallback: a live item whose pre-generated thumbnail is missing (a
        // newly published clip, say) still needs a still. This pulls its first
        // frame natively instead of spinning up a decoder per grid tile.
        val thumbs = VideoThumbnailChannel(applicationContext)
        videoThumbnailChannel = thumbs
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VideoThumbnailChannel.CHANNEL,
        ).setMethodCallHandler(thumbs)

        // Share-time watermark: Transformer burns the Dart-rendered full-frame
        // PNG overlay into the shared MP4 copy (the original stays clean).
        val watermark = ShareWatermarkChannel(applicationContext)
        shareWatermarkChannel = watermark
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ShareWatermarkChannel.CHANNEL,
        ).setMethodCallHandler(watermark)

        // Build provenance — "was this delivered by Play?". Read by the reminders
        // screen to decide whether its notification QA tools are reachable.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BUILD_INFO_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPlayInstall" -> result.success(isPlayInstall())
                else -> result.notImplemented()
            }
        }

        // Targeted share: ACTION_SEND aimed at one package (WhatsApp) so the
        // wallpaper FILE travels with the caption. Stateless and activity-scoped,
        // so it needs no disposal.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DirectShareChannel.CHANNEL,
        ).setMethodCallHandler(DirectShareChannel(this))

        // Ringtone set — WRITE_SETTINGS check/deep-link + MediaStore register +
        // RingtoneManager default-tone set. Ported verbatim from the reference
        // (scoped-storage RELATIVE_PATH path on API 29+, DATA path below).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RINGTONE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canWriteSettings" -> {
                    val canWrite =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            Settings.System.canWrite(this)
                        } else {
                            true // Below API 23 WRITE_SETTINGS is granted at install
                        }
                    result.success(canWrite)
                }

                "openWriteSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent =
                            Intent(
                                Settings.ACTION_MANAGE_WRITE_SETTINGS,
                                Uri.parse("package:$packageName"),
                            )
                        startActivity(intent)
                    }
                    result.success(null)
                }

                "setRingtone" -> {
                    val filePath = call.argument<String>("filePath")
                    val type = call.argument<Int>("type") ?: RingtoneManager.TYPE_RINGTONE

                    if (filePath == null) {
                        result.error("INVALID_ARGS", "filePath is required", null)
                        return@setMethodCallHandler
                    }

                    try {
                        setRingtoneFromFile(filePath, type)
                        result.success(null)
                    } catch (e: SecurityException) {
                        result.error("PERMISSION_DENIED", e.message, null)
                    } catch (e: Exception) {
                        result.error("SET_FAILED", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // A destroyed engine must leave no dangling coroutine jobs, ExoPlayers or
        // SurfaceProducers behind.
        wallpaperApplyChannel?.dispose()
        wallpaperApplyChannel = null
        feedVideoPlugin?.dispose()
        feedVideoPlugin = null
        videoThumbnailChannel?.dispose()
        videoThumbnailChannel = null
        shareWatermarkChannel?.dispose()
        shareWatermarkChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Suppress("DEPRECATION")
    private fun setRingtoneFromFile(filePath: String, type: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !Settings.System.canWrite(this)
        ) {
            throw SecurityException("WRITE_SETTINGS permission not granted")
        }

        val file = File(filePath)
        if (!file.exists()) throw IllegalArgumentException("File not found: $filePath")

        val externalUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val contentUri: Uri

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ (API 29+): scoped storage — use RELATIVE_PATH + openOutputStream
            val values =
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                    put(MediaStore.MediaColumns.MIME_TYPE, "audio/mpeg")
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_RINGTONES,
                    )
                    put(MediaStore.Audio.Media.TITLE, file.nameWithoutExtension)
                    put(MediaStore.Audio.Media.IS_RINGTONE, if (type == RingtoneManager.TYPE_RINGTONE) 1 else 0)
                    put(MediaStore.Audio.Media.IS_NOTIFICATION, if (type == RingtoneManager.TYPE_NOTIFICATION) 1 else 0)
                    put(MediaStore.Audio.Media.IS_ALARM, if (type == RingtoneManager.TYPE_ALARM) 1 else 0)
                    put(MediaStore.Audio.Media.IS_MUSIC, 0)
                }

            // Remove any existing entry with the same name to avoid OEM cache stale tones
            contentResolver.query(
                externalUri,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf(file.name),
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    contentResolver.delete(
                        ContentUris.withAppendedId(externalUri, id),
                        null, null,
                    )
                }
            }

            val uri =
                contentResolver.insert(externalUri, values)
                    ?: throw IllegalStateException("MediaStore insert returned null")

            contentResolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { it.copyTo(out) }
            } ?: throw IllegalStateException("Failed to open output stream")

            contentUri = uri
        } else {
            // Below Android 10: insert with deprecated DATA column
            val values =
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DATA, filePath)
                    put(MediaStore.MediaColumns.TITLE, file.nameWithoutExtension)
                    put(MediaStore.MediaColumns.MIME_TYPE, "audio/mpeg")
                    put(MediaStore.Audio.Media.IS_RINGTONE, if (type == RingtoneManager.TYPE_RINGTONE) 1 else 0)
                    put(MediaStore.Audio.Media.IS_NOTIFICATION, if (type == RingtoneManager.TYPE_NOTIFICATION) 1 else 0)
                    put(MediaStore.Audio.Media.IS_ALARM, if (type == RingtoneManager.TYPE_ALARM) 1 else 0)
                    put(MediaStore.Audio.Media.IS_MUSIC, 0)
                }

            contentUri =
                contentResolver.insert(
                    MediaStore.Audio.Media.getContentUriForPath(filePath)
                        ?: externalUri,
                    values,
                ) ?: throw IllegalStateException("MediaStore insert returned null")
        }

        RingtoneManager.setActualDefaultRingtoneUri(this, type, contentUri)
    }
}
