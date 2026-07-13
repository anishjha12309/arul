# Flutter PhonePe Payment SDK

# Use this Plugin as a library 

1. Add the dependency in flutter project from the command line

        flutter pub add phonepe_payment_sdk

2. Install the dependency from the command line

        flutter pub get

3. Import the package in your dart code :

        import 'package:phonepe_payment_sdk/phonepe_payment_sdk.dart';

# Start Transaction

1. Initialise the init method before starting the transaction. 

        PhonePePaymentSdk.init(environmentValue, merchantId, flowId, enableLogs)
                .then((val) => {
                      setState(() {
                        result = 'PhonePe SDK Initialized - $val';
                      })
                    })
                .catchError((error) {
              handleError(error);
              return <dynamic>{};
            });


2. Start the PG Transaction

        try {
              var response = PhonePePaymentSdk.startTransaction(
                  request, appSchema);
              response
                  .then((val) => {
                        setState(() {
                          result = val;
                        })
                      })
                  .catchError((error) {
                handleError(error);
                return <dynamic>{};
              });
            } catch (error) {
              handleError(error);
            }

##### For more details :
##### Please get in touch with the PhonePe integration team (merchant-integration@phonepe.com)

##### Demo App Link : 
https://github.com/PhonePe/phonepe-pg-sdk-flutter