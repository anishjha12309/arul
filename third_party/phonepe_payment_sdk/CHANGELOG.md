## 3.0.2
1. Android - Fixed bug in payment path due to mappingId.

## 3.0.1
1. Android - Target API 35 version support

## 3.0.0
1. Order-Based Payments
2. Security Improvement
3. Performance Improvement

## 2.0.3
1. Added proguard rules while minifyEnabled true in release version to avoid build issues.

## 2.0.2
1. Remove bitcode in the iOS SDK

## 2.0.1

1. startPGTransaction method is removed

## 1.1.0

1. startPGTransaction method is deprecated now, Please, use startTransaction method.
2. Removed startContainerTransaction method as it is not supported anymore.
3. UAT & UAT_SIM environments are removed & new environment added as SANDBOX for easy integration.
4. New method added to get List of UPI Apps in iOS devices: getInstalledUpiAppsForiOS.


## 1.0.4

* Android transactions, failure responses are improved & will show detailed errors.

## 1.0.3

* Update Native SDKs for better performance

## 1.0.2

* PhonePe Payment SDK Will Support below dependencies:
1.  Dart SDK Version 2.17.0 & above
2.  Flutter SDK Version 3.0.0 & above

## 1.0.1

* Android PhonePe Payment Plugin onActivityResult will handle only B2B PG & Container request codes.

## 1.0.0

* PhonePe Payment Plugin for Flutter Platform