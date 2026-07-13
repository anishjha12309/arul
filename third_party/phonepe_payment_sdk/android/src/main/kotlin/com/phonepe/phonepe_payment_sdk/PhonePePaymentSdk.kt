package com.phonepe.phonepe_payment_sdk

import android.app.Activity
import android.content.Intent
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import com.phonepe.intent.sdk.api.PhonePeKt
import com.phonepe.intent.sdk.api.models.SDKType
import com.phonepe.phonepe_payment_sdk.AppHelperUtil.getUpiAppsForAndroid
import com.phonepe.phonepe_payment_sdk.DataUtil.convertResultToString
import com.phonepe.phonepe_payment_sdk.DataUtil.handleException
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Argument.REQUEST
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Argument.ENABLE_LOGS
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Argument.ENVIRONMENT
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Argument.FLOW_ID
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Argument.MERCHANT_ID
import com.phonepe.phonepe_payment_sdk.GlobalConstants.PHONEPE_PAYMENT_SDK
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Response.ERROR
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Response.FAILURE
import com.phonepe.phonepe_payment_sdk.GlobalConstants.Response.STATUS
import com.phonepe.phonepe_payment_sdk.LogUtil.enableLogs
import com.phonepe.phonepe_payment_sdk.LogUtil.logInfo
import com.phonepe.phonepe_payment_sdk.Method.Companion.getMethod
import com.phonepe.phonepe_payment_sdk.PaymentUtil.init
import com.phonepe.phonepe_payment_sdk.PaymentUtil.startTransaction
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.lang.ref.WeakReference


/** PhonePe Payment Sdk Plugin */
class PhonePePaymentSdk : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var result: Result
    private lateinit var activity: WeakReference<Activity>
    private var activityResultLauncher: ActivityResultLauncher<Intent>? = null

    init {
        PhonePeKt.setAdditionalInfo(SDKType.FLUTTER)
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, PHONEPE_PAYMENT_SDK)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        logInfo("started ${call.method}")
        this.result = result
        when (call.method.getMethod()) {
            Method.INIT -> {
                enableLogs = call.argument<Boolean>(ENABLE_LOGS) ?: false
                activity.init(
                    call.argument<String>(ENVIRONMENT),
                    call.argument<String>(MERCHANT_ID),
                    call.argument<String>(FLOW_ID),
                    enableLogs,
                    result
                )
            }

            Method.START_TRANSACTION ->
                activity.startTransaction(
                    call.argument<String>(REQUEST),
                    activityResultLauncher,
                    result
                )

            Method.NOT_IMPLEMENTED -> result.notImplemented()

            Method.GET_INSTALLED_UPI_APPS -> getUpiAppsForAndroid(result)
        }
    }


    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        logInfo("onDetachedFromEngine")
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        logInfo("onAttachedToActivity")
        activity = WeakReference(binding.activity)

        activityResultLauncher =
            (binding.activity as FlutterFragmentActivity).registerForActivityResult(
                ActivityResultContracts.StartActivityForResult()
            ) { result ->
                // Handle the result
                try {
                    if (result.resultCode != Activity.RESULT_CANCELED)
                        this.result.success(hashMapOf(STATUS to GlobalConstants.Response.SUCCESS))
                    else
                        this.result.success(
                            hashMapOf(
                                STATUS to FAILURE,
                                ERROR to result.data.convertResultToString()
                            )
                        )
                } catch (ex: Exception) {
                    ex.handleException(this.result)
                }
            }
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        logInfo("onDetachedFromActivityForConfigChanges")
        //Do nothing
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        logInfo("onReattachedToActivityForConfigChanges")
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        logInfo("onDetachedFromActivity")
        activity = WeakReference(null)
        channel.setMethodCallHandler(null)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        return false
    }
}
