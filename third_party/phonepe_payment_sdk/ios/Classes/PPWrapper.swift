//
//  PPWrapper.swift
//  phonepe_payment_sdk
//
//  Created by Rajan Arora on 18/07/23.
//

import Flutter
import Foundation
import PhonePePayment

// MARK: FLutter Environment Enum
enum FlutterEnvironment: String {
    case SANDBOX
    case PRODUCTION
    
    subscript() -> Environment {
        switch self {
        case .SANDBOX:
            return .sandbox
        case .PRODUCTION:
            return .production
        }
    }
}

// MARK: class PPWrapper
class PPWrapper {
    
    private init() {}
    
    static let shared = PPWrapper()
    
    var result: FlutterResult?
    
    private var ppPayment: PPPayment?
    private var controller : UIViewController? {
        UIApplication.shared.windows.first?.rootViewController
    }
    
    // MARK: Expose Methods
    
    /// Init should be called first before starting the transaction
    func initSdk(arguments: Any?) {
        let arguments = makeJson(args: arguments)
        
        guard let env = arguments?[Constants.environment] as? String, env.isNotEmpty() else {
            handleError(message: PPError.env.rawValue)
            return
        }
        
        guard let flutterEnv = FlutterEnvironment(rawValue: env) else {
            handleError(message: PPError.flutterEnv.rawValue)
            return
        }
        
        guard let merchantId = arguments?[Constants.merchantId] as? String, merchantId.isNotEmpty() else {
            handleError(message: PPError.merchantId.rawValue)
            return
        }
        
        guard let flowId = arguments?[Constants.flowId] as? String, flowId.isNotEmpty() else {
            handleError(message: PPError.flowId.rawValue)
            return
        }
        
        let enableLogs = arguments?[Constants.enableLogs] as? Bool ?? false
        
        ppPayment = PPPayment(environment: flutterEnv[],
                              flowId: flowId,
                              merchantId: merchantId,
                              enableLogging: enableLogs)
        ppPayment?.setAdditionalInfo(sdkType: .flutter)
        result?(true)
    }
    
    func startTransaction(arguments: Any?) {
        
        guard let viewController = controller else {
            result?(FlutterError(code: Constants.failure,
                                 message: PPError.controller.rawValue,
                                 details: nil))
            return
        }
        
        guard let ppPayment = self.ppPayment else {
            self.result?(FlutterError(code: Constants.failure,
                                      message: PPError.initSDK.rawValue,
                                      details: nil))
            return
        }
        
        makeTransactionRequest(args: arguments) { request, error in
            guard let request = request, error == nil else {
                self.result?(error)
                return
            }
            
            ppPayment.startTransaction(request: request,
                                       on: viewController) { [weak self] _, state in
                self?.handleResult(state: state)
            }
        }
    }
    
    func handleDeepLink(url: URL) -> Bool {
        let isHandled = PPPayment.checkDeeplink(url)
        return isHandled
    }
    
    func getUPIAppsInstalled() {
        result?(PPPayment.getUPIAppsInstalled())
    }
    
    // MARK: Private Methods
    private func makeTransactionRequest(args: Any?, completion:  @escaping ((B2BPGTransactionRequest?, FlutterError?) -> Void)) {
        
        // Transaction Request Details
        let request = makeJson(args: args)
        
        guard let paymentRequest = makePaymentRequest(args: request, checkPaymentFlow: true) else {
            return
        }
        
        guard let paymentType = paymentRequest.paymentMode[Constants.type] as? String else {
            handleError(message: PPError.paymentType.rawValue)
            return
        }
        
        let bankId = paymentRequest.paymentMode[Constants.bankId] as? String ?? ""
        let vpa = paymentRequest.paymentMode[Constants.vpa] as? String ?? ""
        let targetApp = paymentRequest.paymentMode[Constants.targetApp] as? String ?? ""
        
        let mode: PaymentMode
        switch paymentType {
        case Constants.upiIntent:
            mode = .upiIntent(request: UPIIntentPaymentMode(targetApp: targetApp))
        case Constants.netBanking:
            mode = .netBanking(request: NetbankingPaymentMode(bankId: bankId))
        case Constants.upiCollect:
            mode = .upiCollect(request: UpiCollectPaymentMode(message: Constants.collectDetails, details: VPACollectDetails(vpa: vpa)))
        case Constants.ppeIntent:
            mode = .ppeIntent(request: PPEIntentPaymentMode())
        case Constants.payPage:
            mode = .paypage(request: PayPagePaymentMode())
        default:
            completion(nil, FlutterError(code: "-1", message: PPError.inValidType.rawValue, details: nil))
            return
        }
        
        let transactionRequest = B2BPGTransactionRequest(merchantId: paymentRequest.merchantId,
                                                         orderId: paymentRequest.orderId,
                                                         token: paymentRequest.token,
                                                         appSchema: paymentRequest.appSchema,
                                                         paymentMode: mode)
        
        completion(transactionRequest, nil)
    }
    
    private func makePaymentRequest(args: [String: Any]?, checkPaymentFlow: Bool) -> PaymentRequest? {
        
        guard let jsonString = args?[Constants.request] as? String, let requestJson = jsonString.toJson()  else {
            handleError(message: PPError.json.rawValue)
            return nil
        }
        
        guard let orderId = requestJson[Constants.orderId] as? String, orderId.isNotEmpty() else {
            handleError(message: PPError.orderId.rawValue)
            return nil
        }
        
        guard let merchantId = requestJson[Constants.merchantId] as? String, merchantId.isNotEmpty() else {
            handleError(message: PPError.merchantId.rawValue)
            return nil
        }
        
        guard let token = requestJson[Constants.token] as? String, token.isNotEmpty() else {
            handleError(message: PPError.token.rawValue)
            return nil
        }
        
        guard let appSchema = args?[Constants.appSchema] as? String else {
            handleError(message: PPError.appSchema.rawValue)
            return nil
        }
        
        // Payment Mode Details
        guard let paymentMode = requestJson[Constants.paymentMode] as? [String: Any] else {
            handleError(message: PPError.paymentMode.rawValue)
            return nil
        }
        
        return PaymentRequest(merchantId: merchantId,
                              orderId: orderId,
                              token: token,
                              appSchema: appSchema,
                              paymentMode: paymentMode)
    }
    
    private func makeJson(args: Any?) -> [String: Any]? {
        guard let args = args as? [String: Any] else {
            result?(
                FlutterError(
                    code: PPError.typeCaste.rawValue,
                    message: PPError.json.rawValue,
                    details: nil)
            )
            return [:]
        }
        return args
    }
    
    private func handleError(message: String) {
        result?(
            FlutterError(
                code: Constants.failure,
                message: PPError.argument.rawValue,
                details: message))
    }
    
    private func handleResult(state: PPResultState) {
        var dict: [String: String] = [:]
        switch state {
        case .success:
            dict = [Constants.status: Constants.success]
        case .failure(let error):
            dict = [Constants.status: Constants.failure, Constants.error: error.localizedDescription]
        case .interrupted(let error):
            dict = [Constants.status: Constants.interrupted, Constants.error: error.localizedDescription]
        @unknown default:
            dict = [Constants.status: Constants.unknown]
        }
        
        result?(dict)
    }
}
