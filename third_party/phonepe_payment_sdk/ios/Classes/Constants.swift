//
//  Constants.swift
//  phonepe_payment_sdk
//
//  Created by Rajan Arora on 04/09/23.
//

import Foundation

enum PPError: String {
    case env = "Environment not found"
    case flutterEnv = "Environment is in-correct"
    case merchantId = "Merchant Id not found"
    case flowId = "Flow Id not found"
    case controller = "Controller not found"
    case initSDK = "Initialize PhonePe SDK! first"
    case paymentType = "Payment Type not found"
    case inValidType = "Invalid type found"
    case json = "Request Json not found"
    case orderId = "Order Id not found"
    case token = "Token not found"
    case appSchema = "App Schema not found"
    case paymentMode = "Payment Mode not found"
    case typeCaste = "Type Caste Error"
    case argument = "Argument Missing"
}

struct PaymentRequest {
    let merchantId: String
    let orderId: String
    let token: String
    let appSchema: String
    let paymentMode: [String: Any]
}

enum SDKMethodKeys: String {
    case initSDK = "init"
    case isPhonePeInstalled
    case isPaytmAppInstalled
    case isGPayAppInstalled
    case startTransaction
    case getUPIAppsInstalled
}

struct Constants {
    
    //KEYS
    static let environment = "environment"
    static let enableLogs = "enableLogs"
    static let merchantId = "merchantId"
    static let flowId = "flowId"
    static let headers = "headers"
    static let appSchema = "appSchema"
    static let status = "status"
    static let error = "error"
    
    // Values
    static let success = "SUCCESS"
    static let failure = "FAILURE"
    static let interrupted = "INTERRUPTED"
    static let unknown = "UNKNOWN"
    static let collectDetails = "Collect Details"
    
    // Payment Details
    static let request = "request"
    static let orderId = "orderId"
    static let token = "token"
    static let type = "type"
    static let bankId = "bankId"
    static let vpa = "vpa"
    static let targetApp = "targetApp"
    static let paymentMode = "paymentMode"
    
    static let upiIntent = "UPI_INTENT"
    static let netBanking = "NET_BANKING"
    static let upiCollect = "UPI_COLLECT"
    static let ppeIntent = "PPE_INTENT"
    static let payPage = "PAY_PAGE"

}

extension String {
    func toJson() -> [String: Any]? {
        guard let jsonData = self.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: jsonData, options: .allowFragments) as? [String: Any]
    }
    
    func isNotEmpty() -> Bool {
        return !self.isEmpty
    }
}
