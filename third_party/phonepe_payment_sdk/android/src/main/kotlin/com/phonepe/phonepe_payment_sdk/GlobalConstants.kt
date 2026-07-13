package com.phonepe.phonepe_payment_sdk

object GlobalConstants {

    const val PHONEPE_PAYMENT_SDK = "phonepe_payment_sdk"

    object Argument {
        const val ENVIRONMENT = "environment"
        const val MERCHANT_ID = "merchantId"
        const val REQUEST = "request"
        const val ENABLE_LOGS = "enableLogs"
        const val FLOW_ID = "flowId"
    }

    object Environment {
        const val SANDBOX = "SANDBOX"
    }

    object Response {
        const val STATUS = "status"
        const val ERROR = "error"
        const val SUCCESS = "SUCCESS"
        const val FAILURE = "FAILURE"
        const val APPLICATION_NAME = "applicationName"
        const val VERSION = "version"
        const val PACKAGE_NAME = "packageName"
        const val INITIALIZE_PHONEPE_SDK = "Please, Initialize PhonePe SDK!"
    }
}