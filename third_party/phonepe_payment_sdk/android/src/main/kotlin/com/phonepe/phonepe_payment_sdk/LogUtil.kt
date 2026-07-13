package com.phonepe.phonepe_payment_sdk

import android.util.Log

object LogUtil {

    var enableLogs = false

    fun logInfo(message: String) {
        if (enableLogs)
            Log.i(GlobalConstants.PHONEPE_PAYMENT_SDK, message)
    }
}