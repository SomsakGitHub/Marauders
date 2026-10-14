import Foundation

public struct MyLibraryFlowData: Sendable {
    public let accountNo: String
    public let appCode: String
    public let productCode: String

    public init(accountNo: String, appCode: String, productCode: String) {
        self.accountNo = accountNo
        self.appCode = appCode
        self.productCode = productCode
    }
}
