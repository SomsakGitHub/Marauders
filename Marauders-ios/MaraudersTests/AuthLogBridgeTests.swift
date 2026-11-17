import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuthData

/// A line the session module logs must reach the app's log with its level, category and text. The test sets no sink:
/// it passes only when the app pointed the module's log at `AppLog` when it launched.
@Suite(.serialized)
@MainActor
struct AuthLogBridgeTests {
    /// `AppLog` writes from a task of its own, so an entry shows up a moment after the call that logged it.
    private static func entry(_ message: String) async -> AppLogEntry? {
        for _ in 0..<200 {
            let found = AppLogStore.shared.entries.last { $0.category == "auth.bridge" && $0.message == message }
            if let found { return found }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func aLineOfTheModuleReachesTheAppLogAtItsLevel() async {
        let mark = UUID().uuidString
        AuthLog.info("auth.bridge", "info \(mark)")
        AuthLog.warning("auth.bridge", "warning \(mark)")
        AuthLog.error("auth.bridge", "error \(mark)")

        #expect(await Self.entry("info \(mark)")?.level == .info)
        #expect(await Self.entry("warning \(mark)")?.level == .warning)
        #expect(await Self.entry("error \(mark)")?.level == .error)
    }
}
