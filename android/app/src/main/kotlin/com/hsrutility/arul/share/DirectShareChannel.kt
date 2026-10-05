package com.hsrutility.arul.share

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class DirectShareChannel(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/direct_share"

        // WhatsApp's status composer is documented as started for a result; Arul ignores the
        // result, so MainActivity drops this code before the plugin chain sees it.
        const val STATUS_REQUEST_CODE = 5101
        private const val WHATSAPP = "com.whatsapp"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareToPackage" -> shareToPackage(call, result)
            "shareTextToPackage" -> shareTextToPackage(call, result)
            "shareToStatus" -> shareToStatus(call, result)
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

    // Text-only: a targeted ACTION_SEND opens WhatsApp's picker INSIDE Arul's task (its
    // ExternalShareAlias). The `whatsapp://send` link goes through a trampoline that roots the
    // picker in WhatsApp's own task, so the first Back landed on WhatsApp's home, not on Arul.
    private fun shareTextToPackage(call: MethodCall, result: MethodChannel.Result) {
        val targetPackage = call.argument<String>("package")
        val text = call.argument<String>("text")
        if (targetPackage.isNullOrEmpty() || text.isNullOrEmpty()) {
            result.error("bad_input", "package and text are required", null)
            return
        }
        val intent =
            Intent(Intent.ACTION_SEND).apply {
                setPackage(targetPackage)
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            }
        if (intent.resolveActivity(activity.packageManager) == null) {
            result.success(false)
            return
        }
        try {
            activity.startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.success(false)
        } catch (e: SecurityException) {
            result.success(false)
        }
    }

    // WhatsApp's Share to Status API (faq.whatsapp.com/669870872481343): consumer WhatsApp only.
    // EXTRA_STREAM on an ACTION_VIEW is not migrated to ClipData, so the read grant is explicit.
    // false is ROUTINE (no WhatsApp, an old one, Business only) -> Dart falls back to a chat share.
    private fun shareToStatus(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")
        if (filePath.isNullOrEmpty()) {
            result.error("bad_input", "filePath is required", null)
            return
        }
        val file = File(filePath)
        if (!file.exists() || file.length() == 0L) {
            result.error("bad_input", "file not found: $filePath", null)
            return
        }
        val uri: Uri =
            try {
                FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
            } catch (e: IllegalArgumentException) {
                result.success(false)
                return
            }

        val intent =
            Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/status")).apply {
                setPackage(WHATSAPP)
                putExtra("source_app_package_name", activity.packageName)
                putExtra("share_type", "SHARE_TO_STATUS")
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        if (intent.resolveActivity(activity.packageManager) == null) {
            result.success(false)
            return
        }
        try {
            activity.grantUriPermission(WHATSAPP, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, STATUS_REQUEST_CODE)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.success(false)
        } catch (e: SecurityException) {
            result.success(false)
        }
    }
}
