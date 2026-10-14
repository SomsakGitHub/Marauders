import Foundation

public enum MyLibrarySDKCore {
    @MainActor
    public static func initialize(app: MyLibraryAppConfig) {
        MyLibrarySDKCoreManager.shared.configure(app: app)
    }

    @MainActor
    public static var isConfigured: Bool {
        MyLibrarySDKCoreManager.shared.isConfigured
    }

    @MainActor
    public static var configuredHostAppName: String? {
        MyLibrarySDKCoreManager.shared.app?.hostAppName
    }

    @MainActor
    public static var configuredEnvironment: MyLibraryEnvironment? {
        MyLibrarySDKCoreManager.shared.app?.environment
    }
}

@MainActor
final class MyLibrarySDKCoreManager {
    static let shared = MyLibrarySDKCoreManager()

    private(set) var app: MyLibraryAppConfig?

    var isConfigured: Bool { app != nil }

    func configure(app: MyLibraryAppConfig) {
        self.app = app
    }
}
