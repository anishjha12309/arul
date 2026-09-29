package com.hsrutility.arul.auth

import android.content.Context
import android.util.Log
import com.google.android.gms.auth.blockstore.RetrieveBytesResponse
import com.google.android.gms.tasks.Task
import com.google.android.gms.auth.blockstore.Blockstore
import com.google.android.gms.auth.blockstore.DeleteBytesRequest
import com.google.android.gms.auth.blockstore.RetrieveBytesRequest
import com.google.android.gms.auth.blockstore.StoreBytesData
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// The session in Google's Block Store: it outlives an uninstall on the same phone (Backup on) and
// moves to a new phone on restore, so a returning user skips the sign-in wall (docs/auth.md §Session).
// Every failure answers null/false: Block Store is a bonus, never a reason a sign-in fails.
class SessionBackupChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/session_backup"
        private const val KEY = "com.hsrutility.arul.session"
        private const val TAG = "SessionBackup"

        // AnalyticsCohort's first-launch draw, as the shared_preferences plugin stores it.
        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val FIRST_LAUNCH_MARKER = "flutter.analytics_posthog_cohort_draw_v1"
    }

    // Started at engine setup on a first launch only: the read takes ~0.3 s and the sheet request
    // waits on it, so it runs while the engine boots instead of after main() asks.
    private var prefetched: Task<RetrieveBytesResponse>? = null

    fun prefetchIfFirstLaunch() {
        try {
            val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            if (prefs.contains(FIRST_LAUNCH_MARKER)) return
            prefetched = client.retrieveBytes(retrieveRequest())
        } catch (e: Exception) {
            Log.w(TAG, "prefetch failed: ${e.javaClass.simpleName}")
        }
    }

    private fun retrieveRequest() = RetrieveBytesRequest.Builder().setKeys(listOf(KEY)).build()

    // Lazy: this handler is registered on every launch, and only a fresh install or a token write
    // ever calls it.
    private val client by lazy { Blockstore.getClient(context.applicationContext) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "read" -> read(result)
                "save" -> save(call.argument<String>("json"), result)
                "clear" -> clear(result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // No Play services, or one too old for Block Store.
            Log.w(TAG, "${call.method} failed: ${e.javaClass.simpleName}")
            result.success(null)
        }
    }

    private fun read(result: MethodChannel.Result) {
        val task = prefetched ?: client.retrieveBytes(retrieveRequest())
        prefetched = null
        task
            .addOnSuccessListener { response ->
                val bytes = response.blockstoreDataMap[KEY]?.bytes
                result.success(bytes?.let { String(it, Charsets.UTF_8) })
            }
            .addOnFailureListener { e ->
                Log.w(TAG, "read failed: ${e.javaClass.simpleName}")
                result.success(null)
            }
    }

    // Cloud backup only when it is end-to-end encrypted (Google's own sample); the local copy that
    // survives a reinstall is written either way.
    private fun save(json: String?, result: MethodChannel.Result) {
        if (json.isNullOrEmpty()) {
            result.success(false)
            return
        }
        client.isEndToEndEncryptionAvailable
            .continueWithTask { e2ee ->
                val data = StoreBytesData.Builder()
                    .setBytes(json.toByteArray(Charsets.UTF_8))
                    .setKey(KEY)
                    .setShouldBackupToCloud(e2ee.isSuccessful && e2ee.result == true)
                    .build()
                client.storeBytes(data)
            }
            .addOnSuccessListener { result.success(true) }
            .addOnFailureListener { e ->
                Log.w(TAG, "save failed: ${e.javaClass.simpleName}")
                result.success(false)
            }
    }

    private fun clear(result: MethodChannel.Result) {
        val request = DeleteBytesRequest.Builder().setKeys(listOf(KEY)).build()
        client.deleteBytes(request)
            .addOnSuccessListener { result.success(true) }
            .addOnFailureListener { e ->
                Log.w(TAG, "clear failed: ${e.javaClass.simpleName}")
                result.success(false)
            }
    }
}
