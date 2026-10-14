import XCTest
@testable import MyLibrarySDKCore

@MainActor
final class MyLibrarySDKCoreTests: XCTestCase {
    func testInitializeSetsConfiguredState() {
        MyLibrarySDKCore.initialize(
            app: MyLibraryAppConfig(hostAppName: "ios-demo", environment: .sit, debugMode: true)
        )
        XCTAssertTrue(MyLibrarySDKCore.isConfigured)
        XCTAssertEqual(MyLibrarySDKCore.configuredHostAppName, "ios-demo")
        XCTAssertEqual(MyLibrarySDKCore.configuredEnvironment, .sit)
    }
}
