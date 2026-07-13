import 'dart:io';

import 'package:flutter/services.dart';

class PhonePePaymentSdk {
  static const MethodChannel _channel = MethodChannel('phonepe_payment_sdk');

  /*
   * This method is used to initiate PhonePe Payment sdk.
   * Provide all the information as requested by the method signature.
   * Params:
   *    - environment: This signified the environment required for the payment sdk
   *      possible values: SANDBOX, PRODUCTION
   *      if any unknown value is provided, PRODUCTION will be considered as default.
   *    - merchantId: The merchant id provided by PhonePe at the time of onboarding.
   *    - flowId : An alphanumeric string without any special character. It acts as a common ID b/w
   *      your app user journey and PhonePe SDK. This helps to debug prod issue. 
   *      Recommended - Pass user-specific information or merchant user-id to track the journey.
   *    - enableLogging: If you want to enable / visualize sdk log @IOS
   *        - enable = YES
   *        - disable = NO
   */
  static Future<bool> init(String environment, String merchantId, String flowId,
      bool enableLogging) async {
    bool result = await _channel.invokeMethod('init', {
      'environment': environment,
      'merchantId': merchantId,
      'flowId': flowId,
      'enableLogs': enableLogging,
    });
    return result;
  }

  /*
    * This method is used to initiate PhonePe Transaction Flow.
    * Provide all the information as requested by the method signature.
    * Params:
    *    - request : The request body for the transaction as per the developer docs.
    *    - appSchema: @Optional(for Android) Your custom app URL Schemes, as per the developer docs.
    *
    * Return: Will be returning a dictionary / hashMap
    *  {
    *     status: String, // string value to provide the status of the transaction
    *                     // possible values: SUCCESS, FAILURE, INTERRUPTED
    *     error: String   // if any error occurs
    *  }
    */
  static Future<Map<dynamic, dynamic>?> startTransaction(
      String request, String appSchema) async {
    var dict = <String, dynamic>{'request': request, 'appSchema': appSchema};
    Map<dynamic, dynamic>? result =
        await _channel.invokeMethod('startTransaction', dict);
    return result;
  }

/*
   * This method is called to get list of upi apps in @Android only.
   * Return: String
   *  JSON String -> List of UPI App with packageName, applicationName & versionCode
   *  NOTE :- In iOS, it will throw os error at runtime.
   */
  static Future<String?> getUpiAppsForAndroid() async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod('getUpiAppsForAndroid');
    }
    return null;
  }

  /*
   * This method is called to get list of upi apps in @iOS only.
   * Return: Array -> List of UPI Apps name that are installed in the device and supported by PhonePe SDK
   *  NOTE :- In Android, it will throw os error at runtime.
   */
  static Future<List<Object?>?> getInstalledUpiAppsForiOS() async {
    if (Platform.isIOS) {
      return await _channel.invokeMethod('getUPIAppsInstalled');
    }
    return null;
  }
}
