//
//  MyLibraryIntegration.swift
//  Marauders
//

import Foundation
import MyLibrarySDKCoreBinary
import MyLibrarySDKFeatureBinary

@MainActor
enum MyLibraryIntegration {
    private static let appConfig = MyLibraryAppConfig(
        hostAppName: "Marauders",
        environment: .dev,
        debugMode: true
    )

    private static let flowData = MyLibraryFlowData(
        accountNo: "0000000000",
        appCode: "MARAUDERS",
        productCode: "LIB"
    )

    static func configure() {
        MyLibrarySDKCore.initialize(app: appConfig)
    }

    static func present() {
        if !MyLibrarySDKCore.isConfigured {
            configure()
        }

        MyLibrarySDKFeature.startFlow(
            data: flowData,
            onClose: { result in
                AppLog.info("mylibrary", "closed (\(result ?? "dismissed"))")
            }
        )
    }
}
