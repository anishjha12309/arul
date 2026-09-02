package com.hsrutility.arul.share

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Fires an ACTION_SEND straight at ONE app, carrying the wallpaper FILE plus its caption.
// A `whatsapp://send?text=` deep link carries TEXT and nothing else -> it would drop the media and send a bare caption.
// The referral screen can use that scheme because a referral IS just text -> a wallpaper share's payload is the media.
// Only ACTION_SEND with EXTRA_STREAM keeps the file, and only [Intent.setPackage] makes it skip the chooser.
// The file goes through the app's existing FileProvider -> the shared copy lives in the cache dir, which it covers.
// A raw `file://` URI would throw FileUriExposedException on anything since Android 7.
// Contract the Dart caller is built against: shareToPackage {package, filePath, mimeType, text}.
// true means the target app opened and owns the share from here.
// false means the target is missing or cannot take this mime type -> the caller MUST fall back to the system sheet.
// "bad_input" means missing args or a file that is gone.
// `false` is a ROUTINE answer, not a failure -> most installs have no WhatsApp Business and some have no WhatsApp.
class DirectShareChannel(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/direct_share"
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
                // The path sits outside every <paths> entry -> treat it as "cannot direct-share", not as an error.
                result.success(false)
                return
            }

        val intent =
            Intent(Intent.ACTION_SEND).apply {
                setPackage(targetPackage)
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                if (!text.isNullOrEmpty()) putExtra(Intent.EXTRA_TEXT, text)
                // Without this the target app gets a URI it may not read -> the share lands as a broken attachment.
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

        // Resolve BEFORE starting -> an unresolvable targeted intent throws, and a clean false is what the caller needs.
        // Both WhatsApp packages are declared in <queries> -> package visibility does not hide them from this check.
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
