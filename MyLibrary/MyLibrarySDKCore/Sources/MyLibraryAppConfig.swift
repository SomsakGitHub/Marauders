import Foundation

public struct MyLibraryAppConfig: Sendable {
    public let hostAppName: String
    public let environment: MyLibraryEnvironment
    public let debugMode: Bool

    public init(hostAppName: String, environment: MyLibraryEnvironment, debugMode: Bool = false) {
        self.hostAppName = hostAppName
        self.environment = environment
        self.debugMode = debugMode
    }
}

public enum MyLibraryEnvironment: String, Sendable {
    case dev, sit, uat, prod
}
