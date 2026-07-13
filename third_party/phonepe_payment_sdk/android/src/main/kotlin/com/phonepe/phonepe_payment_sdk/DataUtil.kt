package com.phonepe.phonepe_payment_sdk

import android.content.Intent
import com.phonepe.intent.sdk.api.PhonePeInitException
import io.flutter.plugin.common.MethodChannel

object DataUtil {

    fun Intent?.convertResultToString(): String {
        var result = ""
        if (this?.extras != null && this.extras!!.keySet().size > 0)
            for (key in this.extras!!.keySet()) result += "$key:${this.extras!![key]}\n"
        return result
    }

    fun Exception.handleException(result: MethodChannel.Result) {
        LogUtil.logInfo("handleException: ${this.localizedMessage}")
        when (this) {
            is PhonePeInitException, is UninitializedPropertyAccessException -> result.error(
                GlobalConstants.Response.FAILURE,
                GlobalConstants.Response.INITIALIZE_PHONEPE_SDK, null
            )

            is IllegalArgumentException -> result.error(
                GlobalConstants.Response.FAILURE,
                this.localizedMessage, null
            )

            else -> result.success(
                hashMapOf(
                    GlobalConstants.Response.STATUS to GlobalConstants.Response.FAILURE,
                    GlobalConstants.Response.ERROR to this.localizedMessage
                )
            )
        }
    }
}