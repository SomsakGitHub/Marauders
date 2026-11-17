import Foundation
import MaraudersAuth

/// The sandbox marker disappears on uninstall; Keychain credentials may survive.
enum InstallationSessionGuard {
    private(set) static var isReady = false

    static func bootstrap() {
        guard !AppRuntimeConfiguration.isUITesting else { return }
        do {
            try resetIfNeeded(
                marker: try markerURL(),
                sessionStore: KeychainAuthSessionStore(), tokenStore: KeychainAPIAccessTokenStore(),
                refreshTokenStore: KeychainAPIRefreshTokenStore())
            isReady = true
        } catch {
            // Never restore old credentials when the reset or marker write fails.
            isReady = false
            AppLog.error("auth", "installation session reset failed; session restoration disabled")
        }
    }

    /// Where the marker of a finished install check is kept.
    static func markerURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Installation/session-initialized")
    }

    static func resetIfNeeded(
        marker: URL, sessionStore: any AuthSessionStore, tokenStore: any APIAccessTokenStore,
        refreshTokenStore: any APIRefreshTokenStore
    ) throws {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        // Do not create the marker unless every credential has been removed.
        try tokenStore.clearAccessToken()
        try refreshTokenStore.clearRefreshToken()
        try sessionStore.clear()
        var directory = marker.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try Data("1".utf8).write(to: marker, options: .atomic)
    }
}
