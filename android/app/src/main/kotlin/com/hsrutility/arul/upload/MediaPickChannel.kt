package com.hsrutility.arul.upload

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// The upload screen's one file pick, straight on the system pickers.
// It replaced the file_picker plugin, whose Android side carried Apache Tika for MIME sniffing ->
// 370 KB of dex + XML for a job UploadConstraints.mimeFromName does from the extension anyway.
// Neither picker needs a permission -> the manifest stays free of READ_MEDIA_*, which Play's
// Photo and Video Permissions policy would otherwise ask this app to justify.
// A wallpaper pick is the Android Photo Picker (androidx's PickVisualMedia contract builds the
// intent and carries Google's own fallbacks: the system picker on 13+, the Play-services one where
// it is installed, else ACTION_OPEN_DOCUMENT) -> an image or video, never audio.
// A ringtone pick is ACTION_GET_CONTENT on audio/* opened at the audio root, exactly what the
// plugin launched -> the same picker people have learnt, with music apps free to answer it.
// The picked content:// stream is copied into the app cache and the COPY's path is returned ->
// Dart reads a plain File, and a provider that revokes the grant on return cannot cut it off.
// Contract the Dart caller is built against: pick(kind) -> {path, name} or null when dismissed.
// The copy is Dart's to delete once it is rejected or replaced; this side only sweeps at engine start.
class MediaPickChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/media_pick"
        const val REQUEST_PICK = 0x4D50 // "MP" -> unique among this activity's requests
        private const val TAG = "MediaPickChannel"
        private const val CACHE_DIR = "upload_picks"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var pending: MethodChannel.Result? = null

    private val picksDir = File(activity.cacheDir, CACHE_DIR)

    init {
        // Every engine starts with an empty pick cache: nothing Dart holds survives a new isolate,
        // so this is the one moment a sweep cannot pull a file out from under a pick or an upload.
        // Mid-session the copies are Dart's to delete (a rejected pick, a replaced one), never ours.
        scope.launch { picksDir.deleteRecursively() }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call.argument<String>("kind"), result)
            else -> result.notImplemented()
        }
    }

    private fun pick(kind: String?, result: MethodChannel.Result) {
        // A pending call whose picker already went away (Activity recreated under it) would
        // otherwise block every later pick -> the newer call always wins, the older reads as dismissed.
        pending?.success(null)
        pending = result
        val intent = if (kind == "audio") audioIntent() else visualMediaIntent()
        try {
            // No resolveActivity pre-flight: package-visibility filtering lies, the try/catch IS the probe.
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            Log.w(TAG, "no picker for kind=$kind", e)
            pending = null
            result.error("NO_PICKER", e.message, null)
        }
    }

    private fun visualMediaIntent(): Intent {
        val request = PickVisualMediaRequest.Builder()
            .setMediaType(PickVisualMedia.ImageAndVideo)
            .build()
        return PickVisualMedia().createIntent(activity, request)
    }

    private fun audioIntent(): Intent = Intent(Intent.ACTION_GET_CONTENT).apply {
        type = "audio/*"
        addCategory(Intent.CATEGORY_OPENABLE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val audioRoot = DocumentsContract.buildRootUri(
                "com.android.providers.media.documents",
                "audio_root",
            )
            putExtra(DocumentsContract.EXTRA_INITIAL_URI, audioRoot)
        }
    }

    /** Returns true when the result was this channel's; MainActivity then skips the plugin chain. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pending ?: return true
        pending = null
        // The Photo Picker may answer through clipData rather than data -> the contract reads both.
        val uri = PickVisualMedia().parseResult(resultCode, data)
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        scope.launch {
            try {
                val copied = copyToCache(uri)
                withContext(Dispatchers.Main) {
                    result.success(mapOf("path" to copied.absolutePath, "name" to copied.name))
                }
            } catch (e: CancellationException) {
                throw e // the engine is going away -> nobody is left to answer
            } catch (e: Exception) {
                Log.w(TAG, "copy failed for $uri", e)
                withContext(Dispatchers.Main) { result.error("COPY_FAILED", e.message, null) }
            }
        }
        return true
    }

    // Each pick gets its own directory -> a second pick can never overwrite or delete the first,
    // whose file Dart may still be validating, showing, or reading for an upload in flight.
    private fun copyToCache(uri: Uri): File {
        val dir = File(picksDir, System.nanoTime().toString())
        dir.mkdirs()
        val target = File(dir, fileName(uri))
        val input = activity.contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("provider returned no stream")
        input.use { source -> target.outputStream().use { source.copyTo(it) } }
        return target
    }

    // The provider's display name, because its extension is what the MIME allow-list reads.
    // A provider that gives none, or one without an extension (some Photo Picker rows, some OEM
    // galleries), gets one from the provider's own MIME type -> the allow-list still sees a real file.
    private fun fileName(uri: Uri): String {
        var name: String? = null
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) name = c.getString(0) }
        // File(..).name strips any path a provider smuggled into the display name.
        val base = name?.takeIf { it.isNotBlank() }?.let { File(it).name } ?: "pick"
        if (base.contains('.')) return base
        val ext = activity.contentResolver.getType(uri)
            ?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
        return if (ext.isNullOrBlank()) base else "$base.$ext"
    }

    fun dispose() {
        pending = null
        scope.cancel()
    }
}
