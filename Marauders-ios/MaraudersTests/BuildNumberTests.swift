import Foundation
import Testing

@testable import Marauders

/// The build number the gate compares with the Worker's minimum (docs/adr/012-force-update.md): the app's own
/// `CFBundleVersion`, read as digits and nothing else, so an odd value can never become a number that stops the app.
struct BuildNumberTests {
    @Test(arguments: [("17", 17), (" 17 ", 17), ("1", 1), ("0", 0)])
    func digitsAreTheBuildNumber(text: String, number: Int) {
        #expect(BuildNumber.parse(text) == number)
    }

    /// Nothing, blanks, a version string, a suffix, a sign, and a number too big for an `Int` are no build number.
    @Test(arguments: [nil, "", "   ", "1.0", "1b", "-3", "+3", "99999999999999999999"] as [String?])
    func anythingElseIsNoBuildNumber(text: String?) {
        #expect(BuildNumber.parse(text) == nil)
    }

    @Test func theBuiltAppCarriesAnIntegerBuildNumber() {
        #expect(BuildNumber.current != nil)
    }

    /// The unit tests run in the Debug-Staging configuration, which defines `DEBUG`: if that stopped being true, a
    /// developer's build with a number above 1 could be stopped by the gate.
    @Test func theTestConfigurationIsADebugBuild() {
        #expect(BuildNumber.isDebugBuild)
    }
}
