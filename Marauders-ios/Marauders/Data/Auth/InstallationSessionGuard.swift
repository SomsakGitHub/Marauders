import Foundation

/// The sandbox marker disappears on uninstall; Keychain credentials may survive.
enum InstallationSessionGuard {
    private(set) static var isReady = false

    static func bootstrap() {
        guard !AppRuntimeConfiguration.isUITesting else { return }
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try resetIfNeeded(marker: root.appendingPathComponent("Installation/session-initialized"),
                              sessionStore: KeychainAuthSessionStore(), tokenStore: KeychainAPIAccessTokenStore())
            isReady = true
        } catch {
            // Never restore old credentials when the reset or marker write fails.
            isReady = false
            AppLog.error("auth", "installation session reset failed; session restoration disabled")
        }
    }

    static func resetIfNeeded(marker: URL, sessionStore: any AuthSessionStore, tokenStore: any APIAccessTokenStore) throws {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        // Do not create the marker unless both credentials have been removed.
        try tokenStore.clearAccessToken()
        try sessionStore.clear()
        var directory = marker.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try Data("1".utf8).write(to: marker, options: .atomic)
    }
}
