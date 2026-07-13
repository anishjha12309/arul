package com.phonepe.phonepe_payment_sdk

enum class Method(val method: String?) {
    INIT("init"),
    START_TRANSACTION("startTransaction"),
    GET_INSTALLED_UPI_APPS("getUpiAppsForAndroid"),
    NOT_IMPLEMENTED(null);

    companion object {
        fun String?.getMethod(): Method {
            return values().firstOrNull { it.method == this } ?: NOT_IMPLEMENTED
        }
    }
}