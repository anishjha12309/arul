package com.hsrapps.arul

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
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
        private const val TAG = "MainActivity"

        // Ringtone set channel (ported from the reference app's ringtone block).
        private const val RINGTONE_CHANNEL = "com.hsrapps.arul/ringtone_set"

        // Runtime-permission request code for the pre-Android-10 WRITE_EXTERNAL_STORAGE
        // grant a custom ringtone needs there (see setRingtone / onRequestPermissionsResult).
        private const val STORAGE_PERMISSION_REQUEST = 5001

        // Exposes isPlayInstall() to Dart — see that function, and the QA-tools
        // gate in the reminders screen.
        private const val BUILD_INFO_CHANNEL = "com.hsrapps.arul/build_info"
    }

    private var wallpaperApplyChannel: WallpaperApplyChannel? = null
    private var feedVideoPlugin: FeedVideoPlugin? = null
    private var videoThumbnailChannel: VideoThumbnailChannel? = null
    private var shareWatermarkChannel: ShareWatermarkChannel? = null

    // A setRingtone call parked while the pre-Q WRITE_EXTERNAL_STORAGE prompt is
    // shown; resumed (or failed) in onRequestPermissionsResult. Only one is ever
    // in flight — the ringtone row shows a per-item spinner and blocks re-taps.
    private var pendingRingtonePath: String? = null
    private var pendingRingtoneTitle: String? = null
    private var pendingRingtoneMime: String? = null
    private var pendingRingtoneType: Int = RingtoneManager.TYPE_RINGTONE
    private var pendingRingtoneResult: MethodChannel.Result? = null

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
                        openWriteSettingsScreen()
                    }
                    result.success(null)
                }

                "setRingtone" -> {
                    val filePath = call.argument<String>("filePath")
                    val title = call.argument<String>("title")
                    val mime = call.argument<String>("mime")
                    val type = call.argument<Int>("type") ?: RingtoneManager.TYPE_RINGTONE

                    if (filePath == null) {
                        result.error("INVALID_ARGS", "filePath is required", null)
                        return@setMethodCallHandler
                    }

                    // Pre-Android-10 needs WRITE_EXTERNAL_STORAGE to register the tone
                    // on the external MediaStore volume (Android 10+ uses scoped
                    // storage and needs nothing). If it's missing, prompt for it and
                    // resume the set in onRequestPermissionsResult; otherwise set now.
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                        checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        pendingRingtonePath = filePath
                        pendingRingtoneTitle = title
                        pendingRingtoneMime = mime
                        pendingRingtoneType = type
                        pendingRingtoneResult = result
                        requestPermissions(
                            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                            STORAGE_PERMISSION_REQUEST,
                        )
                        return@setMethodCallHandler
                    }

                    completeRingtoneSet(filePath, title, mime, type, result)
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

    /**
     * Opens the "modify system settings" grant screen. The per-package form of
     * ACTION_MANAGE_WRITE_SETTINGS is not resolvable on every OEM build (some
     * MIUI/ColorOS/Transsion settings apps ship only the app-list form), and
     * startActivity throws ActivityNotFoundException there — so this walks a
     * fallback chain instead of crashing: per-package grant page → app-list
     * grant page → this app's details page (resolvable everywhere). Never
     * throws; if every intent fails the tap is a no-op and the permission
     * sheet stays up for a retry.
     */
    private fun openWriteSettingsScreen() {
        val candidates = listOf(
            Intent(
                Settings.ACTION_MANAGE_WRITE_SETTINGS,
                Uri.parse("package:$packageName"),
            ),
            Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"),
            ),
        )
        for (intent in candidates) {
            try {
                startActivity(intent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "write-settings intent unresolvable, trying fallback", e)
            }
        }
        Log.e(TAG, "No settings screen resolvable for WRITE_SETTINGS grant")
    }

    /**
     * Resumes (or fails) a setRingtone call that was parked to prompt for the
     * pre-Android-10 WRITE_EXTERNAL_STORAGE permission.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != STORAGE_PERMISSION_REQUEST) return

        val result = pendingRingtoneResult
        val path = pendingRingtonePath
        val title = pendingRingtoneTitle
        val mime = pendingRingtoneMime
        val type = pendingRingtoneType
        pendingRingtoneResult = null
        pendingRingtonePath = null
        pendingRingtoneTitle = null
        pendingRingtoneMime = null
        pendingRingtoneType = RingtoneManager.TYPE_RINGTONE
        if (result == null || path == null) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            result.error(
                "PERMISSION_DENIED",
                "Storage access is needed to set a ringtone on this Android version.",
                null,
            )
            return
        }
        completeRingtoneSet(path, title, mime, type, result)
    }

    /** Runs the actual ringtone set for [filePath] and completes [result]. */
    private fun completeRingtoneSet(
        filePath: String,
        title: String?,
        mime: String?,
        type: Int,
        result: MethodChannel.Result,
    ) {
        try {
            setRingtoneFromFile(filePath, title, mime, type)
            result.success(null)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            result.error("SET_FAILED", e.message, null)
        }
    }

    /**
     * The tone's human-visible name in the system sound picker. The download is
     * named by catalog id (a stable cache key the user should never see), so the
     * catalog title is threaded through the channel and sanitized here: path
     * separators + control chars stripped, whitespace collapsed, capped at 60
     * chars, falling back to the raw filename when blank/absent.
     */
    private fun ringtoneToneTitle(title: String?, file: File): String {
        val cleaned = title.orEmpty()
            .replace(Regex("[\\\\/\\p{Cntrl}]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()
            .take(60)
        return cleaned.ifBlank { file.nameWithoutExtension }
    }

    /**
     * Removes our stale MediaStore rows matching [selection] before re-inserting
     * the tone. On Android 10+ rows created by a PREVIOUS install of the app are
     * no longer owned by us — deleting them throws RecoverableSecurityException
     * (a SecurityException). That must NOT abort the set (it would permanently
     * break re-setting any tone the user set before a reinstall): skip instead —
     * MediaStore uniquifies the new row's DISPLAY_NAME ("name (1).mp3"), which
     * is harmless. Never throws.
     */
    private fun deleteStaleRingtoneRows(
        externalUri: Uri,
        selection: String,
        selectionArgs: Array<String>,
    ) {
        try {
            contentResolver.query(
                externalUri,
                arrayOf(MediaStore.MediaColumns._ID),
                selection,
                selectionArgs,
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    try {
                        contentResolver.delete(
                            ContentUris.withAppendedId(externalUri, id),
                            null, null,
                        )
                    } catch (e: SecurityException) {
                        Log.w(TAG, "Skipping non-owned stale ringtone row $id", e)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Stale ringtone row cleanup failed (non-critical)", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun setRingtoneFromFile(
        filePath: String,
        title: String?,
        mime: String?,
        type: Int,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !Settings.System.canWrite(this)
        ) {
            throw SecurityException("WRITE_SETTINGS permission not granted")
        }

        val file = File(filePath)
        if (!file.exists()) throw IllegalArgumentException("File not found: $filePath")

        val toneTitle = ringtoneToneTitle(title, file)
        val ext = file.extension.takeIf { it.isNotBlank() } ?: "mp3"
        val displayName = "$toneTitle.$ext"
        // Real content type from the catalog; some OEM media scanners re-derive
        // type from the extension and misindex rows whose MIME disagrees.
        val resolvedMime = mime?.takeIf { it.isNotBlank() } ?: "audio/mpeg"

        val externalUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val contentUri: Uri

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ (API 29+): scoped storage — use RELATIVE_PATH + openOutputStream
            val values =
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                    put(MediaStore.MediaColumns.MIME_TYPE, resolvedMime)
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        Environment.DIRECTORY_RINGTONES,
                    )
                    put(MediaStore.Audio.Media.TITLE, toneTitle)
                    put(MediaStore.Audio.Media.IS_RINGTONE, if (type == RingtoneManager.TYPE_RINGTONE) 1 else 0)
                    put(MediaStore.Audio.Media.IS_NOTIFICATION, if (type == RingtoneManager.TYPE_NOTIFICATION) 1 else 0)
                    put(MediaStore.Audio.Media.IS_ALARM, if (type == RingtoneManager.TYPE_ALARM) 1 else 0)
                    put(MediaStore.Audio.Media.IS_MUSIC, 0)
                }

            // Best-effort removal of our previous entry for this tone so repeat
            // sets don't pile up rows / serve an OEM-cached stale tone.
            deleteStaleRingtoneRows(
                externalUri,
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf(displayName),
            )

            val uri =
                contentResolver.insert(externalUri, values)
                    ?: throw IllegalStateException("MediaStore insert returned null")

            contentResolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { it.copyTo(out) }
            } ?: throw IllegalStateException("Failed to open output stream")

            contentUri = uri
        } else {
            // Below Android 10 (API < 29): the downloaded tone lives in our app-
            // PRIVATE cache (/data/data/<pkg>/cache), which the system ringtone
            // player — a different process — cannot read; and inserting that
            // internal path routed the row to the read-only `internal` MediaStore
            // volume, which never validates as a ringtone ("Uri is not ringtone,
            // alarm, or notification"). Both were seen on-device (Pakiza). Fix: copy
            // the tone into the PUBLIC Ringtones directory (world-readable +
            // indexable) and register THAT path on the EXTERNAL volume. The copy +
            // the external insert both need WRITE_EXTERNAL_STORAGE, already ensured
            // granted by the caller on this API level.
            val ringtonesDir =
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_RINGTONES)
            if (!ringtonesDir.exists() && !ringtonesDir.mkdirs()) {
                throw IllegalStateException("Could not create the Ringtones directory.")
            }
            val destFile = File(ringtonesDir, displayName)
            file.copyTo(destFile, overwrite = true)

            // Drop any stale row for this exact path so re-setting the same tone
            // doesn't collide with a leftover entry carrying different flags.
            deleteStaleRingtoneRows(
                externalUri,
                "${MediaStore.MediaColumns.DATA} = ?",
                arrayOf(destFile.absolutePath),
            )

            val values =
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DATA, destFile.absolutePath)
                    put(MediaStore.MediaColumns.TITLE, toneTitle)
                    put(MediaStore.MediaColumns.MIME_TYPE, resolvedMime)
                    put(MediaStore.Audio.Media.IS_RINGTONE, if (type == RingtoneManager.TYPE_RINGTONE) 1 else 0)
                    put(MediaStore.Audio.Media.IS_NOTIFICATION, if (type == RingtoneManager.TYPE_NOTIFICATION) 1 else 0)
                    put(MediaStore.Audio.Media.IS_ALARM, if (type == RingtoneManager.TYPE_ALARM) 1 else 0)
                    put(MediaStore.Audio.Media.IS_MUSIC, 0)
                }

            contentUri =
                contentResolver.insert(externalUri, values)
                    ?: throw IllegalStateException("MediaStore insert returned null")
        }

        RingtoneManager.setActualDefaultRingtoneUri(this, type, contentUri)
    }
}
