package com.phonepe.phonepe_payment_sdk

import android.app.Activity
import android.content.Intent
import androidx.activity.result.ActivityResultLauncher
import com.phonepe.intent.sdk.api.PhonePeKt
import com.phonepe.intent.sdk.api.models.PhonePeEnvironment
import com.phonepe.intent.sdk.api.models.transaction.primitive.TransactionRequest
import com.phonepe.phonepe_payment_sdk.DataUtil.handleException
import io.flutter.plugin.common.MethodChannel
import org.json.JSONException
import org.json.JSONObject
import java.lang.ref.WeakReference
import com.phonepe.intent.sdk.api.models.transaction.primitive.TransactionRequest as TransactionRequestV2Primitive

object PaymentUtil {

    fun WeakReference<Activity>.init(
        environment: String?,
        merchantId: String?,
        flowId: String?,
        enableLogs: Boolean,
        result: MethodChannel.Result
    ) {
        try {
            if (environment.isNullOrEmpty() || merchantId.isNullOrEmpty() || flowId.isNullOrEmpty() || get() == null)
                throw IllegalArgumentException("Invalid environment or merchantId or flowId!")

            val ppEnvironment = when (environment) {
                GlobalConstants.Environment.SANDBOX -> PhonePeEnvironment.SANDBOX
                else -> PhonePeEnvironment.RELEASE
            }

            result.success(
                PhonePeKt.init(
                    get()!!,
                    merchantId,
                    flowId ?: "",
                    ppEnvironment,
                    enableLogs
                )
            )

        } catch (ex: Exception) {
            ex.handleException(result)
        }
    }

    fun WeakReference<Activity>.startTransaction(
        request: String?,
        activityResultLauncher: ActivityResultLauncher<Intent>?,
        result: MethodChannel.Result
    ) {
        try {
            if (request.isNullOrEmpty() || get() == null)
                throw IllegalArgumentException("Invalid body!")

            val transactionRequest = getTransactionRequest(request)

            if (activityResultLauncher != null) {
                PhonePeKt.startTransaction(
                    get()!!,
                    transactionRequest,
                    activityResultLauncher
                )
            }
        } catch (ex: Exception) {
            ex.handleException(result)
        }
    }

    private fun getTransactionRequest(request: String): TransactionRequest {
        val requestBody = JSONObject(request)
        val orderId = requestBody.optString("orderId")
        if (orderId.isNullOrEmpty())
            throw JSONException("Invalid orderId!")

        val token = requestBody.optString("token")
        if (token.isNullOrEmpty())
            throw JSONException("Invalid token!")

        val paymentMode= requestBody.optString("paymentMode")
        if (paymentMode.isNullOrEmpty())
            throw JSONException("Invalid paymentMode!")

        val targetAppPackageName = requestBody.optString("targetAppPackageName") // Optional

        return TransactionRequestV2Primitive(
            orderId, token, requestBody.toString(), targetAppPackageName
        )
    }
}