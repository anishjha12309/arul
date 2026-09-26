package com.hsrutility.arul.update

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.appupdate.testing.FakeAppUpdateManager
import com.google.android.play.core.install.InstallException
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Play's in-app update, driven from Dart (docs/app-update.md): check -> start -> completeUpdate.
// Every Play call is Task-listener async on main -> a blocking Tasks.await here would be an ANR.
// Sideloads, emulators and debug installs fail the check (API_NOT_AVAILABLE / APP_NOT_OWNED) -> Dart no-ops.
class AppUpdateChannel(
    activity: Activity,
    private val launcher: ActivityResultLauncher<IntentSenderRequest>,
    private val channel: MethodChannel,
    // Sideload-only test mode (MainActivity passes it only for a non-Play install): Play's own
    // FakeAppUpdateManager replays accept / reject / download so the whole flow runs on a test phone.
    private val fakeMode: String? = null,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.hsrutility.arul/app_update"
        const val FAKE_EXTRA = "arul_fake_update"
        private const val TAG = "ArulUpdate"
        private const val FAKE_BUILD = 999
        private const val FAKE_STEP_MS = 1500L
    }

    private val fake: FakeAppUpdateManager? =
        fakeMode?.let { mode ->
            FakeAppUpdateManager(activity.applicationContext).apply {
                setUpdateAvailable(
                    FAKE_BUILD,
                    if (mode == "flexible") AppUpdateType.FLEXIBLE else AppUpdateType.IMMEDIATE,
                )
            }
        }
    private val manager: AppUpdateManager = fake ?: AppUpdateManagerFactory.create(activity.applicationContext)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingFlow: MethodChannel.Result? = null
    private var listening = false
    private val installListener = InstallStateUpdatedListener { state ->
        channel.invokeMethod("onInstallState", statusName(state.installStatus()))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "check" -> check(result)
            "start" -> start(call.argument<String>("type"), result)
            "completeUpdate" ->
                manager.completeUpdate().addOnCompleteListener {
                    fake?.let { f -> Log.w(TAG, "fake: completeUpdate installSplash=${f.isInstallSplashScreenVisible}") }
                    result.success(it.isSuccessful)
                }
            "isFake" -> result.success(fake != null)
            else -> result.notImplemented()
        }
    }

    private fun check(result: MethodChannel.Result) {
        manager.appUpdateInfo
            .addOnSuccessListener { info ->
                if (fake != null) Log.w(TAG, "fake: check -> ${availabilityName(info.updateAvailability())}")
                result.success(
                    mapOf(
                        "availability" to availabilityName(info.updateAvailability()),
                        "availableBuild" to info.availableVersionCode(),
                        "immediateAllowed" to
                            info.isUpdateTypeAllowed(AppUpdateOptions.defaultOptions(AppUpdateType.IMMEDIATE)),
                        "flexibleAllowed" to
                            info.isUpdateTypeAllowed(AppUpdateOptions.defaultOptions(AppUpdateType.FLEXIBLE)),
                        "installStatus" to statusName(info.installStatus()),
                        "stalenessDays" to info.clientVersionStalenessDays(),
                        "priority" to info.updatePriority(),
                    ),
                )
            }
            .addOnFailureListener { e ->
                result.error("UNAVAILABLE", ((e as? InstallException)?.errorCode ?: -1).toString(), null)
            }
    }

    // One AppUpdateInfo starts ONE flow (Play docs) -> re-read it instead of reusing the check's.
    private fun start(type: String?, result: MethodChannel.Result) {
        val updateType = if (type == "flexible") AppUpdateType.FLEXIBLE else AppUpdateType.IMMEDIATE
        manager.appUpdateInfo
            .addOnSuccessListener { info ->
                val options = AppUpdateOptions.newBuilder(updateType).build()
                val startable =
                    when (info.updateAvailability()) {
                        UpdateAvailability.UPDATE_AVAILABLE -> info.isUpdateTypeAllowed(options)
                        // An immediate update the process lost (kill, icon relaunch) -> the docs resume it.
                        UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS ->
                            updateType == AppUpdateType.IMMEDIATE
                        else -> false
                    }
                if (!startable) {
                    result.success("not_allowed")
                    return@addOnSuccessListener
                }
                if (updateType == AppUpdateType.FLEXIBLE && !listening) {
                    manager.registerListener(installListener)
                    listening = true
                }
                pendingFlow?.success("superseded")
                pendingFlow = result
                val started =
                    try {
                        manager.startUpdateFlowForResult(info, launcher, options)
                    } catch (e: Exception) {
                        false
                    }
                if (!started && pendingFlow === result) {
                    pendingFlow = null
                    result.success("failed")
                }
                if (started) fake?.let { simulate(it, updateType) }
            }
            .addOnFailureListener { result.success("failed") }
    }

    // A successful IMMEDIATE update restarts the app -> RESULT_OK may never arrive, and that is fine.
    fun onFlowResult(resultCode: Int) {
        if (fake != null) Log.w(TAG, "fake: flow result $resultCode")
        val pending = pendingFlow ?: return
        pendingFlow = null
        pending.success(
            when (resultCode) {
                Activity.RESULT_OK -> "accepted"
                Activity.RESULT_CANCELED -> "cancelled"
                else -> "failed"
            },
        )
    }

    private fun simulate(f: FakeAppUpdateManager, updateType: Int) {
        val immediate = updateType == AppUpdateType.IMMEDIATE
        Log.w(TAG, "fake: flow started immediate=$immediate visible=${f.isImmediateFlowVisible || f.isConfirmationDialogVisible}")
        mainHandler.postDelayed({
            if (fakeMode == "immediate_cancel") {
                f.userRejectsUpdate()
                Log.w(TAG, "fake: user rejected")
                onFlowResult(Activity.RESULT_CANCELED)
                f.setUpdateAvailable(FAKE_BUILD, AppUpdateType.IMMEDIATE)
                return@postDelayed
            }
            f.userAcceptsUpdate()
            if (immediate) {
                Log.w(TAG, "fake: user accepted")
                onFlowResult(Activity.RESULT_OK)
                // Re-offered, so one run can prove every later check point prompts too.
                f.setUpdateAvailable(FAKE_BUILD, AppUpdateType.IMMEDIATE)
                return@postDelayed
            }
            f.downloadStarts()
            Log.w(TAG, "fake: user accepted, download started")
            onFlowResult(Activity.RESULT_OK)
            mainHandler.postDelayed({
                f.downloadCompletes()
                Log.w(TAG, "fake: download completed")
            }, FAKE_STEP_MS)
        }, FAKE_STEP_MS)
    }

    fun dispose() {
        mainHandler.removeCallbacksAndMessages(null)
        if (listening) manager.unregisterListener(installListener)
        listening = false
        pendingFlow = null
    }

    private fun availabilityName(availability: Int) =
        when (availability) {
            UpdateAvailability.UPDATE_AVAILABLE -> "available"
            UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS -> "in_progress"
            UpdateAvailability.UPDATE_NOT_AVAILABLE -> "none"
            else -> "unknown"
        }

    private fun statusName(status: Int) =
        when (status) {
            InstallStatus.PENDING -> "pending"
            InstallStatus.DOWNLOADING -> "downloading"
            InstallStatus.DOWNLOADED -> "downloaded"
            InstallStatus.INSTALLING -> "installing"
            InstallStatus.INSTALLED -> "installed"
            InstallStatus.FAILED -> "failed"
            InstallStatus.CANCELED -> "canceled"
            else -> "unknown"
        }
}
