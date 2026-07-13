import Flutter
import UIKit
import PhonePePayment


public class PhonePePaymentSdk: NSObject, FlutterPlugin {
    
    // Register the Channel
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "phonepe_payment_sdk", binaryMessenger: registrar.messenger())
        let instance = PhonePePaymentSdk()
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        
        let wrapper = PPWrapper.shared
        wrapper.result = result
        
        let method = SDKMethodKeys(rawValue: call.method)
        
        switch method {
        case .initSDK:
            wrapper.initSdk(arguments: call.arguments)
        case .startTransaction:
            wrapper.startTransaction(arguments: call.arguments)
        case .getUPIAppsInstalled:
            wrapper.getUPIAppsInstalled()
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    public func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        return PPWrapper.shared.handleDeepLink(url: url)
    }
    
}
