import Foundation
import Testing
@testable import Marauders

@MainActor
struct InstallationSessionGuardTests {
    @Test func freshInstallClearsSurvivingKeychainButNextLaunchKeepsSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = root.appendingPathComponent("session-initialized")
        let service = "test.installation." + UUID().uuidString
        let session = KeychainAuthSessionStore(service: service)
        let token = KeychainAPIAccessTokenStore(service: service)
        defer {
            try? session.clear()
            try? token.clearAccessToken()
            try? FileManager.default.removeItem(at: root)
        }
        try session.saveUserID("001234.abcdef.5678")
        try token.saveAccessToken(String(repeating: "a", count: 32))
        try InstallationSessionGuard.resetIfNeeded(marker: marker, sessionStore: session, tokenStore: token)
        #expect(session.loadUserID() == nil)
        #expect(token.loadAccessToken() == nil)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        try session.saveUserID("001234.abcdef.5678")
        try token.saveAccessToken(String(repeating: "b", count: 32))
        try InstallationSessionGuard.resetIfNeeded(marker: marker, sessionStore: session, tokenStore: token)
        #expect(session.loadUserID() != nil)
        #expect(token.loadAccessToken() == String(repeating: "b", count: 32))

        // Simulate uninstall removing the sandbox while Keychain survives.
        try FileManager.default.removeItem(at: root)
        try InstallationSessionGuard.resetIfNeeded(marker: marker, sessionStore: session, tokenStore: token)
        #expect(session.loadUserID() == nil)
        #expect(token.loadAccessToken() == nil)
    }

    @Test func resetFailureDoesNotMarkInstallationComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = root.appendingPathComponent("session-initialized")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try InstallationSessionGuard.resetIfNeeded(marker: marker, sessionStore: KeychainAuthSessionStore(service: "test.unused"), tokenStore: FailingResetTokenStore())
            Issue.record("Expected failed credential deletion")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
private struct FailingResetTokenStore: APIAccessTokenStore {
    enum Failure: Error { case clear }
    func loadAccessToken() -> String? { nil }
    func saveAccessToken(_ token: String) throws {}
    func clearAccessToken() throws { throw Failure.clear }
}
