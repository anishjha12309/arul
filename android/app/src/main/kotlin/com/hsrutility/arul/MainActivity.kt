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

// FlutterFragmentActivity, not FlutterActivity: the PhonePe Payment SDK requires it,
// and switching later would mean re-testing the whole activity lifecycle. Costs nothing now.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val TAG = "MainActivity"

        // Ringtone set channel (ported from the reference app's ringtone block).
        private const val RINGTONE_CHANNEL = "com.hsrutility.arul/ringtone_set"

        // Runtime-permission request code for the pre-Android-10 WRITE_EXTERNAL_STORAGE
        // grant a custom ringtone needs there (see setRingtone / onRequestPermissionsResult).
        private const val STORAGE_PERMISSION_REQUEST = 5001

        // Exposes isPlayInstall() to Dart — see that function, and the QA-tools
        // gate in the reminders screen.
        private const val BUILD_INFO_CHANNEL = "com.hsrutility.arul/build_info"

        // Google Analytics for Firebase's documented deferred-deep-link storage.
        // The SDK may write this before OR after Flutter attaches, so onCreate
        // buffers it and the MethodChannel supports both an initial pull and a
        // later push. See docs/deferred-links.md.
        private const val GOOGLE_DDL_PREFS = "google.analytics.deferred.deeplink.prefs"
        private const val GOOGLE_DDL_KEY = "deeplink"

        // ONE bridge for every network-delivered deferred link — Google Ads via
        // GA4F above, Meta via the FB SDK (fetchMetaDeferredLink). Handled
        // tokens persist, so a delivery is honoured once per install however
        // many Activity creations it spans.
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

    // Deferred links waiting for Flutter's ACK, keyed by token (the URL) in
    // arrival order. UI thread only.
    private val pendingDeferredLinks = LinkedHashMap<String, Map<String, Any>>()

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
        registerGoogleDeferredLinkListener()
        fetchMetaDeferredLink()
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

        // Deferred deep links (Google Ads via GA4F, Meta via the FB SDK).
        // `getDeferredDeepLinks` covers values captured before the engine
        // attached; `onDeferredDeepLink` covers ones captured later. Flutter
        // ACKs only after it has durably saved the target, so an Activity /
        // process death cannot lose it.
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

        // Direct UPI-intent mandate: paywall picker enumeration + launching the
        // PhonePe intentUrl aimed at the chosen UPI app. Stateless and
        // activity-scoped, so it needs no disposal.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UpiIntentChannel.CHANNEL,
        ).setMethodCallHandler(UpiIntentChannel(this))

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

    /**
     * Starts listening before Flutter attaches and immediately reads the current
     * value. Firebase documents both paths as necessary: registering late can
     * miss the preference-change callback, while only reading once can miss a
     * network response that arrives later in startup.
     */
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
            // Loud on purpose. An ad group whose App URL is anything other than
            // https://arul.hsrutility.com/w/<uuid> or /r/<uuid> (a ?lang= query
            // is fine) fails COMPLETELY silently otherwise, and the shipped
            // build is FLAG_SECURE, so logcat is the only window on it. See
            // docs/deferred-links.md §Google Ads DDL.
            Log.w(TAG, "Deferred deep link ignored: not a /w/ or /r/ App Link")
            return
        }

        // The URL alone is the delivery identity — NOT url+timestamp. GA4F writes
        // its `deeplink` and `timestamp` keys independently, so a composite token
        // reads "0:<url>" on the launch that captures the link and "<bits>:<url>"
        // once the timestamp lands: the handled marker stops matching and an
        // already-consumed wallpaper re-opens on some later launch. DDL is
        // install-scoped anyway (new users only, 24h window), so re-delivering the
        // same URL is never something to honour.
        enqueueDeferredLink(raw, SOURCE_GOOGLE_ADS)
    }

    /**
     * Meta deferred deep link: the URL an ad's deep-link field carried, for a
     * user who installed from that ad (docs/deferred-links.md §Meta).
     * `AppLinkData.fetchDeferredAppLinkData` asks Meta's Graph API once
     * (`DEFERRED_APP_LINK`) — it logs NO app event and touches none of the
     * SDK's auto-logging flags, so Meta's install/launch attribution events
     * are unaffected. The SDK itself was initialised by its manifest
     * ContentProvider (AutoInitEnabled) before this Activity existed.
     *
     * Attempted on the first launches after install until Meta answers with
     * data or three launches have tried: the SDK reports "no link" and "the
     * network failed" identically (a null callback), and a first launch with no
     * signal must not throw the ad's target away forever. Never throws — a link
     * is never worth a crash on the launch path.
     */
    private fun fetchMetaDeferredLink() {
        try {
            val state = getSharedPreferences(DEFERRED_STATE_PREFS, MODE_PRIVATE)
            // Re-offer a link captured on an earlier Activity that Flutter never
            // ACKed; the handled set inside enqueue keeps it once-only.
            state.getString(META_LINK_KEY, null)?.let { enqueueDeferredLink(it, SOURCE_META) }
            if (state.getBoolean(META_DONE_KEY, false)) return
            val attempts = state.getInt(META_ATTEMPTS_KEY, 0)
            if (attempts >= META_MAX_ATTEMPTS) return
            // No META_APP_ID baked into this build (key-less dev) — nothing to ask.
            if (!FacebookSdk.isInitialized() || FacebookSdk.getApplicationId().isNullOrBlank()) return
            state.edit().putInt(META_ATTEMPTS_KEY, attempts + 1).apply()

            AppLinkData.fetchDeferredAppLinkData(applicationContext) { appLinkData ->
                // Background thread: persist, then hop to the UI thread to enqueue.
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
        // getStringSet's instance must never be mutated in place — copy it.
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

    /**
     * Opens the "modify system settings" grant screen. The per-package form of
     * ACTION_MANAGE_WRITE_SETTINGS is not resolvable on every OEM build (some
     * MIUI/ColorOS/Transsion settings apps ship only the app-list form), and
     * startActivity throws ActivityNotFoundException there — so this walks a
     * fallback chain instead of crashing: per-package grant page → app-list
     * grant page → this app's details page (resolvable everywhere). Never
     * throws; the Set tap now opens this screen directly with no explainer in
     * front of it, so if every intent fails the tap is a silent no-op —
     * accepted, since a build with no resolvable settings screen has no path
     * to the grant anyway.
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
     * Shields the PhonePe plugin's activity-result callback.
     *
     * `phonepe_payment_sdk` 3.0.2 (latest on pub.dev, 2026-08-26) registers an
     * ActivityResult launcher in onAttachedToActivity whose callback completes a
     * `lateinit var result` that startTransaction() sets. When Android recreates
     * this process while PhonePe's B2bPgActivity is on top (2 GB phones, itel /
     * Tecno class), the registry replays the pending result into a FRESH plugin
     * instance that never saw a startTransaction — `UninitializedPropertyAccess-
     * Exception` on the main thread, the one real crash in the Crashlytics list
     * (13 users / 30 days, 2026-08-26), and it fires at the exact moment the user
     * returns from paying. The result carries nothing we need: the mandate's
     * outcome is reconciled from the server when the paywall reopens
     * (`/payments/status` on open — PremiumScreen._reconcileOnOpen), and the
     * `trial_started` conversion is recovered by TrialConversionCatchUp. So the
     * dropped result costs nothing; the crash cost the celebration.
     *
     * Deliberately narrow: only that exception class, everything else propagates.
     */
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
        if (type == RingtoneManager.TYPE_RINGTONE) applyPerSimRingtones(contentUri)
    }

    /**
     * Per-SIM ringtone rows that some OEM skins - not AOSP - actually read when a
     * SIM call comes in.
     *
     * [RingtoneManager.setActualDefaultRingtoneUri] writes only the AOSP default
     * (`Settings.System.RINGTONE`). Dual-SIM skins (OxygenOS/ColorOS, MIUI/
     * HyperOS, Funtouch, and the AOSP MSIM patch set Nothing OS also carries)
     * route each SIM's incoming call through its OWN `Settings.System` row and
     * never consult the AOSP one, so setting a tone here changed WhatsApp's call
     * ringtone (WhatsApp DOES read the AOSP default) while the phone itself kept
     * ringing with the old tone - reported on a OnePlus 15, 2026-08-21.
     *
     * ONE tone on EVERY slot, never a per-SIM choice: the same URI is written to
     * the AOSP default and to every ringtone row the device carries, so a call on
     * SIM 2 rings with what the user just picked (owner's call, 2026-08-21).
     *
     * The names are OEM-private and undocumented, so they are DISCOVERED, not
     * guessed - see [discoverRingtoneKeys]. This list is only the fallback for a
     * device that refuses to be enumerated, and each entry is (ringtone key, its
     * `_set` marker): the marker is a second presence probe, never something we
     * write, because on the attached Nothing device `ringtone_sim2` exists while
     * holding NULL and only `ringtone_set_sim2` = "1" reveals it. See
     * [isDeclaredSetting]. A device matching neither route gets nothing written.
     */
    private val fallbackPerSimRingtoneKeys =
        listOf(
            "ringtone_sim1" to "ringtone_set_sim1",
            "ringtone_sim2" to "ringtone_set_sim2",
            "ringtone_2" to "ringtone_set_2",
            "ringtone2" to "ringtone_set2",
        )

    /**
     * Best-effort extra on top of a ringtone set that has ALREADY succeeded.
     * Every write is individually wrapped: a skin that protects or rejects its
     * own key must never turn a working ringtone change into a failure the user
     * sees.
     */
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

    /**
     * Every ringtone-slot row THIS device actually carries, read off the settings
     * provider instead of guessed.
     *
     * Guessing is what the first cut did, and it can only ever cover skins someone
     * here has held: the reported failure was a OnePlus nobody can query. query()
     * on `Settings.System.CONTENT_URI` lists the rows by name, so a skin that
     * calls its second slot something we have never heard of still gets the tone.
     *
     * The filter is deliberately loose on the name and strict on the VALUE, since
     * a name match alone would let a non-ringtone row through:
     *  - must MENTION "ringtone" (contains, not startsWith, so a vendor-prefixed
     *    name like `oplus_ringtone_sim2` is caught) but must not BE `ringtone` -
     *    that one is the AOSP default, already written by
     *    [RingtoneManager.setActualDefaultRingtoneUri] in its own normalised form,
     *    and overwriting it with ours would fight the framework;
     *  - never a `_set` marker (holds "1"), a decoded-path `cache`, or a
     *    vibrate/volume/silent flag - none of them take a URI;
     *  - the existing value must be absent or already a URI. A row we cannot read
     *    (Android 12+ hides `@hide` rows) comes back null and is ACCEPTED, which
     *    is the case that matters: `ringtone_sim2` reads as null on a device that
     *    has never had a per-SIM tone set.
     */
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
            // Provider not enumerable on this skin - fall back to the known names.
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

    /**
     * Whether THIS device's framework declares [key] as a setting - the guard that
     * keeps a skin without per-SIM ringtones from gaining junk rows.
     *
     * Two ways to be true, and the second is the one that carries the weight.
     * Android 12+ refuses to let an ordinary app READ a declared-but-`@hide`
     * setting and throws `SecurityException: Settings key: <x> is not readable`,
     * while a name the framework does not declare at all is unrestricted and just
     * reads back null. Confirmed on the attached Nothing device: `ringtone_sim2`
     * throws (it exists, OEM-private) and `ringtone_sim1` returns null (no such
     * setting). So the throw IS the presence signal, not a failure - an earlier
     * version treated it as one and skipped the only key that mattered. Writing
     * is unaffected by the read restriction; WRITE_SETTINGS still governs it.
     */
    private fun isDeclaredSetting(key: String): Boolean =
        try {
            Settings.System.getString(contentResolver, key) != null
        } catch (e: SecurityException) {
            true
        } catch (e: Exception) {
            false
        }
}
