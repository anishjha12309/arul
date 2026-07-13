package com.phonepe.phonepe_payment_sdk

import com.phonepe.intent.sdk.api.PhonePeKt
import com.phonepe.phonepe_payment_sdk.DataUtil.handleException
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

object AppHelperUtil {

    fun getUpiAppsForAndroid(result: MethodChannel.Result) {
        try {
            val jsonArray = JSONArray()
            val apps = PhonePeKt.getUpiApps()
            for (app in apps) {
                jsonArray.put(JSONObject().apply {
                    put(GlobalConstants.Response.PACKAGE_NAME, app.packageName)
                    put(GlobalConstants.Response.APPLICATION_NAME, app.applicationName)
                    put(GlobalConstants.Response.VERSION, app.version.toString())
                })
            }
            result.success(jsonArray.toString())
        } catch (ex: Exception) {
            ex.handleException(result)
        }
    }
}