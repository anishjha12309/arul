package com.hsrutility.arul.status

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// Saves a status clip into the shared Movies/Arul collection, one fresh entry per save.
// API 29+ needs no permission for its own MediaStore inserts; API <= 28 needs WRITE_EXTERNAL_STORAGE
// (declared maxSdkVersion=28), prompted here on the first save and never at launch.
class StatusSaveChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/status_save"

        // 5001 is the ringtone prompt's -> each pre-Q prompt parks its own call.
        const val STORAGE_PERMISSION_REQUEST = 5002
        private const val TAG = "StatusSave"
        private const val ALBUM = "Arul"
        private const val MIME = "video/mp4"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // A save parked behind the pre-Q storage prompt -> [onPermissionResult] resumes or fails it.
    private var pending: Triple<String, String, MethodChannel.Result>? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveVideo") {
            result.notImplemented()
            return
        }
        val filePath = call.argument<String>("filePath")
        val displayName = call.argument<String>("displayName")
        if (filePath.isNullOrEmpty() || displayName.isNullOrEmpty()) {
            result.error("bad_input", "filePath and displayName are required", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            // A second tap while the prompt is up replaces nothing -> the first call still owns it.
            if (pending != null) {
                result.error("busy", "a save is already waiting for the storage prompt", null)
                return
            }
            pending = Triple(filePath, displayName, result)
            activity.requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                STORAGE_PERMISSION_REQUEST,
            )
            return
        }
        save(filePath, displayName, result)
    }

    /** Called by MainActivity for [STORAGE_PERMISSION_REQUEST] only. */
    fun onPermissionResult(granted: Boolean) {
        val parked = pending ?: return
        pending = null
        val (filePath, displayName, result) = parked
        if (!granted) {
            result.error("permission_denied", "storage permission refused", null)
            return
        }
        save(filePath, displayName, result)
    }

    // Off the main thread: a whole-file copy through the media provider is seconds on a budget phone.
    private fun save(filePath: String, displayName: String, result: MethodChannel.Result) {
        scope.launch {
            val outcome: Result<String> =
                try {
                    val source = File(filePath)
                    if (!source.isFile || source.length() == 0L) {
                        throw IllegalArgumentException("source not readable: $filePath")
                    }
                    Result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            saveScoped(source, displayName)
                        } else {
                            saveLegacy(source, displayName)
                        },
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "status save failed", e)
                    Result.failure(e)
                }
            withContext(Dispatchers.Main) {
                try {
                    outcome.fold(
                        onSuccess = { result.success(it) },
                        onFailure = { result.error("save_failed", it.message, null) },
                    )
                } catch (e: Exception) {
                    // A dead engine's Result can throw -> the file is already written or not.
                    Log.w(TAG, "could not deliver save result", e)
                }
            }
        }
    }

    // IS_PENDING hides the row from other apps until the bytes are complete; a failed copy deletes it.
    private fun saveScoped(source: File, displayName: String): String {
        val resolver = activity.contentResolver
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, MIME)
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                "${Environment.DIRECTORY_MOVIES}/$ALBUM",
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert returned null")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                source.inputStream().use { it.copyTo(out) }
            } ?: throw IllegalStateException("could not open the new entry")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (ignored: Exception) {
                // The half-written row stays pending, which hides it from every other app.
            }
            throw e
        }
        return uri.toString()
    }

    // Below API 29 MediaStore has no RELATIVE_PATH -> write the public Movies/Arul file, then let the
    // scanner index it, as the shared-media guide does for Android 9 and lower.
    @Suppress("DEPRECATION")
    private fun saveLegacy(source: File, displayName: String): String {
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
            ALBUM,
        )
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("could not create ${dir.absolutePath}")
        }
        val dest = File(dir, displayName)
        source.copyTo(dest, overwrite = false)
        MediaScannerConnection.scanFile(
            activity.applicationContext,
            arrayOf(dest.absolutePath),
            arrayOf(MIME),
            null,
        )
        return dest.absolutePath
    }

    fun dispose() {
        scope.cancel()
        // The engine is going away and its Result with it -> nothing to answer.
        pending = null
    }
}
