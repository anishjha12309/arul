package com.hsrutility.arul

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.SharedPreferences
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
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.facebook.FacebookSdk
import com.facebook.applinks.AppLinkData
import com.hsrutility.arul.feedvideo.FeedVideoPlugin
import com.hsrutility.arul.payments.UpiIntentChannel
import com.hsrutility.arul.feedvideo.VideoThumbnailChannel
import com.hsrutility.arul.share.DirectShareChannel
import com.hsrutility.arul.share.ShareWatermarkChannel
import com.hsrutility.arul.wallpaper.WallpaperApplyChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// PhonePe's Payment SDK requires FlutterFragmentActivity, not FlutterActivity -> never switch it back.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val TAG = "MainActivity"

        private const val RINGTONE_CHANNEL = "com.hsrutility.arul/ringtone_set"

        // Request code for the pre-Android-10 WRITE_EXTERNAL_STORAGE grant a custom ringtone needs there.
        private const val STORAGE_PERMISSION_REQUEST = 5001

        // Exposes isPlayInstall() to Dart -> the reminders screen gates its QA tools on it.
        private const val BUILD_INFO_CHANNEL = "com.hsrutility.arul/build_info"

        // Firebase's documented deferred-deep-link storage -> the SDK may write it before OR after Flutter attaches.
        // So onCreate buffers the value and the channel serves both an initial pull and a later push.
        private const val GOOGLE_DDL_PREFS = "google.analytics.deferred.deeplink.prefs"
        private const val GOOGLE_DDL_KEY = "deeplink"

        // ONE bridge for every network-delivered deferred link -> Google Ads via GA4F, Meta via the FB SDK.
        // Handled tokens persist -> a delivery is honoured once per install, however many Activity creations it spans.
        private const val DEFERRED_LINK_CHANNEL = "com.hsrutility.arul/deferred_link"
        private const val DEFERRED_STATE_PREFS = "arul.deferred_link"
        private const val DEFERRED_HANDLED_TOKENS_KEY = "handled_tokens"
        private const val META_LINK_KEY = "meta_link"
        private const val META_DONE_KEY = "meta_done"
        private const val META_ATTEMPTS_KEY = "meta_attempts"
        private const val META_MAX_ATTEMPTS = 3
        private const val SOURCE_GOOGLE_ADS = "google_ads"
        private const val SOURCE_META = "meta"
        private const val DEEP_LINK_HOST = "arul.hsrutility.com"
        private val UUID_RE =
            Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    }

    private var wallpaperApplyChannel: WallpaperApplyChannel? = null
    private var feedVideoPlugin: FeedVideoPlugin? = null
    private var videoThumbnailChannel: VideoThumbnailChannel? = null
    private var shareWatermarkChannel: ShareWatermarkChannel? = null
    private var deferredLinkChannel: MethodChannel? = null
    private var googleDeferredPrefs: SharedPreferences? = null
    private var googleDeferredListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    // Deferred links awaiting Flutter's ACK, keyed by token (the URL), in arrival order -> UI thread only.
    private val pendingDeferredLinks = LinkedHashMap<String, Map<String, Any>>()

    // A setRingtone parked behind the pre-Q storage prompt -> onRequestPermissionsResult resumes or fails it.
    // Only one is ever in flight -> the ringtone row shows a per-item spinner and blocks re-taps.
    private var pendingRingtonePath: String? = null
    private var pendingRingtoneTitle: String? = null
    private var pendingRingtoneMime: String? = null
    private var pendingRingtoneType: Int = RingtoneManager.TYPE_RINGTONE
    private var pendingRingtoneResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // MUST run before super.onCreate() -> the library installs into the window before content exists.
        // This is what renders LaunchTheme's splash on API<=30 -> without it those attrs are Android-12-only.
        installSplashScreen()
        super.onCreate(savedInstanceState)
        registerGoogleDeferredLinkListener()
        fetchMetaDeferredLink()
        // FLAG_SECURE blocks screenshots and recording and blanks the recents thumbnail -> Play builds only.
        // No BuildConfig signal separates an APK from an AAB (both are `release`) -> the installer package is the proxy.
        // Sideloaded release APKs stay visible -> Play-listing screenshots still work -> that difference is intended.
        // Set here, not in the manifest -> it re-applies on every activity recreate, wallpaper-apply included.
        // release-flag-secure-guard.js gates the .aab on an ACTIVE setFlags call -> never comment this out.
        if (isPlayInstall()) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        }
    }

    // True only when Google Play delivered this build -> that is the uploaded AAB.
    // Fails CLOSED when the installer cannot be resolved -> the published app is never left unprotected.
    // The app's ONE definition of "the artifact Play ships" -> FLAG_SECURE and the reminders QA tools both read it.
    // Keeping them on one predicate is what stops the two from disagreeing -> never fork it.
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

        // getDeferredDeepLinks covers values captured before the engine attached -> onDeferredDeepLink covers later ones.
        // Flutter ACKs only after durably saving the target -> an Activity or process death cannot lose it.
        deferredLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEFERRED_LINK_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeferredDeepLinks" ->
                        result.success(pendingDeferredLinks.values.toList())
                    "ackDeferredDeepLink" -> {
                        val token = call.argument<String>("token")
                        if (token == null || !pendingDeferredLinks.containsKey(token)) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        markDeferredLinkHandled(token)
                        pendingDeferredLinks.remove(token)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        pushPendingDeferredLinks()

        // In-feed live previews -> the Dart VideoPreloadController drives a small REUSE pool of native players.
        // Each renders into a Flutter Texture via a SurfaceProducer -> players are swapped, never recreated.
        // An APPLIED live wallpaper runs in its own WallpaperService (wallpaper/) -> this plugin never touches it.
        feedVideoPlugin = FeedVideoPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        )

        val applyChannel = WallpaperApplyChannel(applicationContext)
        wallpaperApplyChannel = applyChannel
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WallpaperApplyChannel.CHANNEL,
        ).setMethodCallHandler(applyChannel)

        // A live item with no pre-generated thumbnail still needs a still -> pull its first frame natively.
        // The alternative was a decoder per grid tile -> never do that.
        val thumbs = VideoThumbnailChannel(applicationContext)
        videoThumbnailChannel = thumbs
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VideoThumbnailChannel.CHANNEL,
        ).setMethodCallHandler(thumbs)

        // Transformer burns the Dart-rendered full-frame overlay into the SHARED copy -> the original file stays clean.
        val watermark = ShareWatermarkChannel(applicationContext)
        shareWatermarkChannel = watermark
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ShareWatermarkChannel.CHANNEL,
        ).setMethodCallHandler(watermark)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BUILD_INFO_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPlayInstall" -> result.success(isPlayInstall())
                else -> result.notImplemented()
            }
        }

        // ACTION_SEND aimed at ONE package (WhatsApp) -> the wallpaper FILE travels with the caption.
        // Stateless and activity-scoped -> it needs no disposal.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DirectShareChannel.CHANNEL,
        ).setMethodCallHandler(DirectShareChannel(this))

        // Enumerates UPI apps for the paywall picker and launches PhonePe's intentUrl at the chosen one.
        // Stateless and activity-scoped -> it needs no disposal.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UpiIntentChannel.CHANNEL,
        ).setMethodCallHandler(UpiIntentChannel(this))

        // Ringtone set -> WRITE_SETTINGS check and deep-link, MediaStore register, then the default-tone set.
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

                    // Pre-Android-10 needs WRITE_EXTERNAL_STORAGE for the external MediaStore volume -> 10+ needs nothing.
                    // Missing -> prompt and resume the set in onRequestPermissionsResult -> otherwise set now.
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
        // A destroyed engine must leave no dangling coroutine jobs, ExoPlayers or SurfaceProducers behind.
        wallpaperApplyChannel?.dispose()
        wallpaperApplyChannel = null
        feedVideoPlugin?.dispose()
        feedVideoPlugin = null
        videoThumbnailChannel?.dispose()
        videoThumbnailChannel = null
        shareWatermarkChannel?.dispose()
        shareWatermarkChannel = null
        deferredLinkChannel?.setMethodCallHandler(null)
        deferredLinkChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        googleDeferredListener?.let { listener ->
            googleDeferredPrefs?.unregisterOnSharedPreferenceChangeListener(listener)
        }
        googleDeferredListener = null
        googleDeferredPrefs = null
        super.onDestroy()
    }

    // Registering late misses the preference-change callback -> reading once misses a later network response.
    // Firebase documents both paths as necessary -> listen AND read the current value.
    private fun registerGoogleDeferredLinkListener() {
        val prefs = getSharedPreferences(GOOGLE_DDL_PREFS, MODE_PRIVATE)
        googleDeferredPrefs = prefs
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { changed, key ->
            if (key == GOOGLE_DDL_KEY) captureGoogleDeferredLink(changed)
        }
        googleDeferredListener = listener
        prefs.registerOnSharedPreferenceChangeListener(listener)
        captureGoogleDeferredLink(prefs)
    }

    /** Accepts only this app's verified App Link URLs before crossing to Dart. */
    private fun captureGoogleDeferredLink(prefs: SharedPreferences) {
        val raw = prefs.getString(GOOGLE_DDL_KEY, null)?.trim().orEmpty()
        if (raw.isEmpty()) return
        if (!isAppLinkUrl(raw)) {
            // An ad group's App URL must be /w/<uuid> or /r/<uuid> (a ?lang= query is fine) -> anything else is dropped.
            // Dropping it silently is invisible -> the shipped build is FLAG_SECURE, so logcat is the only window.
            Log.w(TAG, "Deferred deep link ignored: not a /w/ or /r/ App Link")
            return
        }

        // The URL ALONE is the delivery identity, never url+timestamp -> GA4F writes those two keys independently.
        // A composite token flips from "0:<url>" to "<bits>:<url>" -> the handled marker stops matching.
        // An already-consumed wallpaper would then re-open on a later launch -> keep the token the bare URL.
        // DDL is install-scoped anyway -> re-delivering the same URL is never something to honour.
        enqueueDeferredLink(raw, SOURCE_GOOGLE_ADS)
    }

    // The URL an ad's deep-link field carried, for a user who installed from it (docs/deferred-links.md §Meta).
    // fetchDeferredAppLinkData asks Meta's Graph API once -> it logs NO app event -> attribution is unaffected.
    // The SDK was already initialised by its manifest ContentProvider -> this Activity does not init it.
    // A null callback means "no link" AND "network failed" -> retry over the first launches, capped at META_MAX_ATTEMPTS.
    // Never throws -> a deferred link is never worth a crash on the launch path.
    private fun fetchMetaDeferredLink() {
        try {
            val state = getSharedPreferences(DEFERRED_STATE_PREFS, MODE_PRIVATE)
            // Re-offer a link an earlier Activity captured but Flutter never ACKed -> enqueue's handled set keeps it once-only.
            state.getString(META_LINK_KEY, null)?.let { enqueueDeferredLink(it, SOURCE_META) }
            if (state.getBoolean(META_DONE_KEY, false)) return
            val attempts = state.getInt(META_ATTEMPTS_KEY, 0)
            if (attempts >= META_MAX_ATTEMPTS) return
            // No META_APP_ID baked in (key-less dev build) -> there is nothing to ask for.
            if (!FacebookSdk.isInitialized() || FacebookSdk.getApplicationId().isNullOrBlank()) return
            state.edit().putInt(META_ATTEMPTS_KEY, attempts + 1).apply()

            AppLinkData.fetchDeferredAppLinkData(applicationContext) { appLinkData ->
                // Background thread -> persist first, then hop to the UI thread to enqueue.
                if (appLinkData != null) state.edit().putBoolean(META_DONE_KEY, true).apply()
                val target = appLinkData?.targetUri?.toString()?.trim().orEmpty()
                if (target.isEmpty()) return@fetchDeferredAppLinkData
                if (!isAppLinkUrl(target) && !isMetaSchemeUrl(target)) {
                    Log.w(TAG, "Meta deferred deep link ignored: not an Arul link")
                    return@fetchDeferredAppLinkData
                }
                state.edit().putString(META_LINK_KEY, target).apply()
                runOnUiThread { enqueueDeferredLink(target, SOURCE_META) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Meta deferred deep link fetch skipped", e)
        }
    }

    /** `https://arul.hsrutility.com/w/<uuid>` or `/r/<uuid>`, any query. */
    private fun isAppLinkUrl(raw: String): Boolean {
        return try {
            val uri = Uri.parse(raw)
            val parts = uri.pathSegments
            uri.scheme.equals("https", ignoreCase = true) &&
                uri.host.equals(DEEP_LINK_HOST, ignoreCase = true) &&
                parts.size == 2 &&
                (parts[0] == "w" || parts[0] == "r") &&
                UUID_RE.matches(parts[1])
        } catch (_: Exception) {
            false
        }
    }

    /** `fb<APP_ID>://open?…` — Meta's custom-scheme form. Dart reads the query. */
    private fun isMetaSchemeUrl(raw: String): Boolean {
        return try {
            val uri = Uri.parse(raw)
            val scheme = uri.scheme.orEmpty()
            scheme.startsWith("fb", ignoreCase = true) &&
                scheme.drop(2).all { it.isDigit() } &&
                (uri.host.isNullOrEmpty() || uri.host.equals("open", ignoreCase = true))
        } catch (_: Exception) {
            false
        }
    }

    /** UI thread only. De-dups against the persisted handled set and the live queue. */
    private fun enqueueDeferredLink(url: String, source: String) {
        val handled = getSharedPreferences(DEFERRED_STATE_PREFS, MODE_PRIVATE)
            .getStringSet(DEFERRED_HANDLED_TOKENS_KEY, null) ?: emptySet()
        if (url in handled || pendingDeferredLinks.containsKey(url)) return
        pendingDeferredLinks[url] = mapOf("url" to url, "token" to url, "source" to source)
        pushPendingDeferredLinks()
    }

    private fun markDeferredLinkHandled(token: String) {
        val prefs = getSharedPreferences(DEFERRED_STATE_PREFS, MODE_PRIVATE)
        // getStringSet's returned instance must never be mutated in place -> copy it before adding.
        val handled = HashSet(prefs.getStringSet(DEFERRED_HANDLED_TOKENS_KEY, null) ?: emptySet())
        handled.add(token)
        prefs.edit().putStringSet(DEFERRED_HANDLED_TOKENS_KEY, handled).apply()
    }

    private fun pushPendingDeferredLinks() {
        val channel = deferredLinkChannel ?: return
        val payloads = pendingDeferredLinks.values.toList()
        if (payloads.isEmpty()) return
        runOnUiThread {
            for (payload in payloads) channel.invokeMethod("onDeferredDeepLink", payload)
        }
    }

    // The per-package ACTION_MANAGE_WRITE_SETTINGS is unresolvable on some OEM builds -> startActivity throws there.
    // So walk a chain: per-package grant page -> app-list grant page -> app details -> the last resolves everywhere.
    // The Set tap opens this with no explainer -> if every intent fails the tap is a silent no-op -> accepted.
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

    // The PhonePe plugin completes a `lateinit var result` that startTransaction() sets -> a fresh instance has none.
    // A process recreate behind B2bPgActivity replays the result into that fresh plugin -> UninitializedPropertyAccessException.
    // It fires exactly as the user returns from paying, on low-memory phones -> swallow it here.
    // The dropped result costs nothing -> /payments/status reconciles on paywall open, TrialConversionCatchUp recovers the event.
    // Deliberately narrow -> only that exception class is caught, everything else propagates.
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        try {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        } catch (e: UninitializedPropertyAccessException) {
            Log.w(
                TAG,
                "Dropped an activity result the PhonePe plugin had no pending call for " +
                    "(process recreated behind its payment page); server reconcile covers it",
                e,
            )
        }
    }

    // Resumes or fails a setRingtone parked behind the pre-Android-10 WRITE_EXTERNAL_STORAGE prompt.
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

    // The download is named by catalog id -> the user must never see that -> the catalog title becomes the picker name.
    // Sanitized here: separators and control chars stripped, whitespace collapsed, capped at 60, filename as fallback.
    private fun ringtoneToneTitle(title: String?, file: File): String {
        val cleaned = title.orEmpty()
            .replace(Regex("[\\\\/\\p{Cntrl}]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()
            .take(60)
        return cleaned.ifBlank { file.nameWithoutExtension }
    }

    // On Android 10+ rows from a PREVIOUS install are no longer ours -> deleting one throws a SecurityException.
    // Aborting there would permanently break re-setting any tone set before a reinstall -> skip the row instead.
    // MediaStore then uniquifies the new DISPLAY_NAME ("name (1).mp3") -> harmless -> this never throws.
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
        // Some OEM media scanners re-derive type from the extension -> a disagreeing MIME misindexes the row.
        val resolvedMime = mime?.takeIf { it.isNotBlank() } ?: "audio/mpeg"

        val externalUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val contentUri: Uri

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ scoped storage -> RELATIVE_PATH plus openOutputStream, never a raw path.
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

            // Repeat sets would pile up rows and let an OEM serve a cached stale tone -> drop our previous entry first.
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
            // Below API 29 the cached tone sits in app-PRIVATE storage -> the ringtone player is another process and cannot read it.
            // Inserting that internal path lands on the read-only `internal` volume -> "Uri is not ringtone, alarm, or notification".
            // So copy it into the PUBLIC Ringtones dir and register THAT path on the EXTERNAL volume.
            // The copy and the external insert both need WRITE_EXTERNAL_STORAGE -> the caller has already ensured it here.
            val ringtonesDir =
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_RINGTONES)
            if (!ringtonesDir.exists() && !ringtonesDir.mkdirs()) {
                throw IllegalStateException("Could not create the Ringtones directory.")
            }
            val destFile = File(ringtonesDir, displayName)
            file.copyTo(destFile, overwrite = true)

            // A leftover row for this exact path carries different flags -> drop it so re-setting the same tone cannot collide.
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
        if (type == RingtoneManager.TYPE_RINGTONE) applyPerSimRingtones(contentUri)
    }

    // setActualDefaultRingtoneUri writes only the AOSP default -> dual-SIM skins read their OWN Settings.System row.
    // So the phone kept ringing with the old tone while WhatsApp, which DOES read the AOSP default, changed.
    // ONE tone on EVERY slot, never a per-SIM choice -> the same URI goes to the default and every ringtone row (owner's call).
    // The key names are OEM-private and undocumented -> DISCOVER them ([discoverRingtoneKeys]) -> this list is only a fallback.
    // Each entry is (ringtone key, its `_set` marker) -> the marker is a second presence probe, never something we write.
    // `ringtone_sim2` can exist holding NULL -> only `ringtone_set_sim2` = "1" reveals it -> see [isDeclaredSetting].
    // A device matching neither route gets nothing written.
    private val fallbackPerSimRingtoneKeys =
        listOf(
            "ringtone_sim1" to "ringtone_set_sim1",
            "ringtone_sim2" to "ringtone_set_sim2",
            "ringtone_2" to "ringtone_set_2",
            "ringtone2" to "ringtone_set2",
        )

    // Best-effort extra on a ringtone set that has ALREADY succeeded -> every write is wrapped individually.
    // A skin that protects or rejects its own key must never turn a working change into a visible failure.
    private fun applyPerSimRingtones(contentUri: Uri) {
        val value = contentUri.toString()
        val keys = discoverRingtoneKeys().ifEmpty { declaredFallbackRingtoneKeys() }
        if (keys.isEmpty()) {
            Log.i(TAG, "No per-SIM ringtone rows on this device; AOSP default only")
            return
        }
        for (key in keys) {
            try {
                Settings.System.putString(contentResolver, key, value)
                Log.i(TAG, "Per-SIM ringtone key updated: $key")
            } catch (e: Exception) {
                Log.w(TAG, "Per-SIM ringtone write failed for $key (non-critical)", e)
            }
        }
    }

    // Read the slot rows off the settings provider instead of guessing -> a skin nobody here owns still gets the tone.
    // The filter is loose on the NAME and strict on the VALUE -> a name match alone would let a non-ringtone row through.
    // Must CONTAIN "ringtone" (so `oplus_ringtone_sim2` is caught) but never BE `ringtone` -> that one is the AOSP default.
    // setActualDefaultRingtoneUri already wrote it in its own normalised form -> overwriting it would fight the framework.
    // Skip `_set` markers, `cache` decoded paths and vibrate/volume/silent flags -> none of them take a URI.
    // The existing value must be absent or already a URI -> a null read is ACCEPTED, not rejected.
    // Android 12+ hides `@hide` rows -> `ringtone_sim2` reads null on a device that never had a per-SIM tone set.
    private fun discoverRingtoneKeys(): List<String> =
        try {
            contentResolver.query(
                Settings.System.CONTENT_URI,
                arrayOf(Settings.NameValueTable.NAME, Settings.NameValueTable.VALUE),
                null,
                null,
                null,
            )?.use { cursor ->
                val found = mutableListOf<String>()
                while (cursor.moveToNext()) {
                    val name = cursor.getString(0) ?: continue
                    val current = if (cursor.columnCount > 1) cursor.getString(1) else null
                    if (isRingtoneSlotRow(name, current)) found += name
                }
                found
            } ?: emptyList()
        } catch (e: Exception) {
            // Provider not enumerable on this skin -> fall back to the known names.
            Log.w(TAG, "Settings.System enumeration unavailable (non-critical)", e)
            emptyList()
        }

    private fun isRingtoneSlotRow(name: String, currentValue: String?): Boolean {
        val n = name.lowercase()
        if (!n.contains("ringtone") || n == "ringtone") return false
        if (n.contains("_set") || n.contains("cache")) return false
        if (n.contains("vibrat") || n.contains("volume") || n.contains("silent")) return false
        val v = currentValue?.trim()
        return v.isNullOrEmpty() || v.startsWith("content://") || v.startsWith("file://")
    }

    /** Fallback path: probe the names we already know, for an unenumerable skin. */
    private fun declaredFallbackRingtoneKeys(): List<String> =
        fallbackPerSimRingtoneKeys
            .filter { (key, marker) -> isDeclaredSetting(key) || isDeclaredSetting(marker) }
            .map { it.first }

    // Whether THIS framework declares [key] -> the guard that keeps a skin without per-SIM rows from gaining junk settings.
    // Android 12+ throws SecurityException reading a declared-but-`@hide` setting -> an UNDECLARED name reads back null.
    // So the THROW is the presence signal, not a failure -> an earlier version skipped the only key that mattered.
    // Reads are restricted, writes are not -> WRITE_SETTINGS still governs the write.
    private fun isDeclaredSetting(key: String): Boolean =
        try {
            Settings.System.getString(contentResolver, key) != null
        } catch (e: SecurityException) {
            true
        } catch (e: Exception) {
            false
        }
}
