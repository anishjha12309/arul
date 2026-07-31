package com.hsrapps.arul.share

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Fires an ACTION_SEND straight at ONE app (WhatsApp), carrying the wallpaper
 * FILE plus its caption, and reports honestly whether it could.
 *
 * Why this exists rather than a `whatsapp://send?text=` deep link: that scheme
 * carries text and nothing else. The referral screen can use it because a
 * referral IS just text, but a wallpaper share's payload is the media — deep
 * linking it would silently drop the image or clip and send a bare caption,
 * which is worse than not targeting WhatsApp at all. Only a real ACTION_SEND
 * with EXTRA_STREAM keeps the file, and only [Intent.setPackage] makes it skip
 * the chooser.
 *
 * The file is exposed through the app's existing FileProvider
 * (`${applicationId}.fileprovider`, see @xml/wallpaper_file_paths) — the shared
 * copy lives in the cache dir, which that config already covers. A raw `file://`
 * URI would throw FileUriExposedException on anything since Android 7.
 *
 * Contract (the Dart caller is built against exactly this):
 *   channel  com.hsrapps.arul/direct_share
 *   method   shareToPackage {package, filePath, mimeType, text}
 *   success  → true  = the target app opened and owns the share from here
 *              false = target not installed, or it cannot receive this mime
 *                      type; the caller MUST fall back to the system sheet
 *   errors   → "bad_input" (missing args, or the file is gone)
 *
 * `false` is a routine answer, not a failure. Most installs will not have
 * WhatsApp Business; some will have no WhatsApp at all.
 */
class DirectShareChannel(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrapps.arul/direct_share"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareToPackage" -> shareToPackage(call, result)
            else -> result.notImplemented()
        }
    }

    private fun shareToPackage(call: MethodCall, result: MethodChannel.Result) {
        val targetPackage = call.argument<String>("package")
        val filePath = call.argument<String>("filePath")
        val mimeType = call.argument<String>("mimeType") ?: "*/*"
        val text = call.argument<String>("text")

        if (targetPackage.isNullOrEmpty() || filePath.isNullOrEmpty()) {
            result.error("bad_input", "package and filePath are required", null)
            return
        }

        val file = File(filePath)
        if (!file.exists() || file.length() == 0L) {
            result.error("bad_input", "file not found: $filePath", null)
            return
        }

        val uri: Uri =
            try {
                FileProvider.getUriForFile(
                    activity,
                    "${activity.packageName}.fileprovider",
                    file,
                )
            } catch (e: IllegalArgumentException) {
                // The path sits outside every <paths> entry. Treat it as "cannot
                // direct-share" rather than an error: the system sheet still can.
                result.success(false)
                return
            }

        val intent =
            Intent(Intent.ACTION_SEND).apply {
                setPackage(targetPackage)
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                if (!text.isNullOrEmpty()) putExtra(Intent.EXTRA_TEXT, text)
                // Without this the target app gets a URI it is not allowed to
                // read, and the share lands as a broken attachment.
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

        // Resolve BEFORE starting: an unresolvable targeted intent throws, and we
        // want a clean false so the caller can fall back. `com.whatsapp` and
        // `com.whatsapp.w4b` are both declared in <queries>, so package
        // visibility does not hide them from this check.
        if (intent.resolveActivity(activity.packageManager) == null) {
            result.success(false)
            return
        }

        try {
            activity.startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            // Raced an uninstall between resolve and launch.
            result.success(false)
        } catch (e: SecurityException) {
            result.success(false)
        }
    }
}
