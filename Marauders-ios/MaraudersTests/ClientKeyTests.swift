import Foundation
import Testing

@testable import Marauders

/// The one build-time value the app holds (`MARAUDERS_CLIENT_KEY`): what counts as a usable value, that the app runs
/// only when it is the pass (`run by pass`), and that nothing prints it. The project holds the pass so a plain Run
/// from Xcode works, and Jenkins overrides it through xcargs.
struct ClientKeyTests {
    private let key = "throwaway-client-key-for-the-tests"

    /// nil and blanks: a build without the setting. The literal: a setting that never expanded. The rest: values that
    /// would break a header or a command line.
    private static let missingOrDirty: [String?] = [
        nil, "", "   ", "\n", "$(MARAUDERS_CLIENT_KEY)", "a\nb", "a\r\nX-Evil: 1", "a\u{0}b",
    ]

    /// Text that only looks like the pass, the old mock, and values `resolve` already rejects.
    private static let notThePass: [String?] = [
        nil, "", "   ", "Run By Pass", "run-by-pass", "run by  pass", "run by pass please", "xrun by pass",
        "mock-client-key-local-only", "$(MARAUDERS_CLIENT_KEY)", "run by pass\nX-Evil: 1",
    ]

    @Test func theConfiguredValueIsUsed() {
        #expect(ClientKey.resolve(configured: key)?.value == key)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(ClientKey.resolve(configured: "  \(key)\n")?.value == key)
    }

    @Test(arguments: ClientKeyTests.missingOrDirty)
    func aMissingOrDirtyValueIsNone(configured: String?) {
        #expect(ClientKey.resolve(configured: configured) == nil)
    }

    @Test func itNeverPrintsItsValue() throws {
        let resolved = try #require(ClientKey.resolve(configured: key))
        var dumped = ""
        dump(resolved, to: &dumped)
        for text in [String(describing: resolved), String(reflecting: resolved), "\(resolved)", dumped] {
            #expect(!text.contains(key))
        }
    }

    @Test func thePassIsTheOneTheOwnerNamed() {
        #expect(ClientKey.pass == "run by pass")
    }

    @Test func thePassIsAcceptedWithSurroundingWhitespace() {
        #expect(ClientKey.accepts(configured: "run by pass"))
        #expect(ClientKey.accepts(configured: "  run by pass\n"))
    }

    @Test(arguments: ClientKeyTests.notThePass)
    func anythingElseIsRefused(configured: String?) {
        #expect(!ClientKey.accepts(configured: configured))
    }

    /// What a plain Run from Xcode relies on: the project's value reaches Info.plist and is the pass.
    @Test func theBuiltAppCarriesThePass() {
        #expect(ClientKey.appMayRun())
    }
}
