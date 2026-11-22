import Foundation
import Testing

@testable import Marauders

/// A well-formed app id of nobody's project: the shape the SDK demands and nothing else.
private let goodAppID = "1:000000000000:ios:0000000000000000"

/// A key of the shape that the SDK's Installations demands (39 characters, an A first, then letters, digits, `-` and
/// `_`) and of nobody's. Built from parts, so that no file of this public repository holds a string that looks like a
/// real key.
private let goodAPIKey = "A" + String(repeating: "0", count: 38)

/// A plist the SDK can start from: the four keys it raises an exception without, all of nobody's. (Computed, because a
/// stored dictionary of `Any` is not safe to share between tests under Swift 6.)
private var goodPlist: [String: Any] {
    [
        "GOOGLE_APP_ID": goodAppID,
        "API_KEY": goodAPIKey,
        "PROJECT_ID": "fixture-not-a-project",
        "GCM_SENDER_ID": "000000000000",
    ]
}

/// `goodPlist` with `key` set to `value`, or left out when `value` is nil.
private func goodPlistWith(_ key: String, _ value: Any?) -> [String: Any] {
    var plist = goodPlist
    plist[key] = value
    return plist
}

/// App ids the SDK would raise on (or that cannot be an iOS app's), as read from the plist; nil is "the key is not in
/// the file".
private let unusableAppIDs: [String?] = [
    nil, "", "1:000000000000:android:abc", "1:000000000000:ios:", "1:000000000000:ios:xyz", "1:abc:ios:abc",
    "2:000000000000:ios:abc", "1:000000000000:ios:abc:extra", " \(goodAppID)", "\(goodAppID) ",
]

/// API keys the SDK's Installations raises on, and the one it would accept but that is not ASCII (the guard is stricter
/// there on purpose: a key from the console is ASCII); nil is "the key is not in the file". The last one is the
/// placeholder the first proof run of this guard crashed the app with.
private let unusableAPIKeys: [String?] = [
    nil,
    "",
    "A",
    String(goodAPIKey.dropLast()),
    goodAPIKey + "0",
    "B" + String(goodAPIKey.dropFirst()),
    String(goodAPIKey.dropLast()) + "!",
    "A " + String(repeating: "0", count: 37),
    "A\n" + String(repeating: "0", count: 37),
    "A\u{E9}" + String(repeating: "0", count: 37),
    "FIXTURE-NOT-A-KEY",
]

/// The guard before `FirebaseApp.configure(options:)` (docs/adr/012-force-update.md): the SDK raises an Objective-C
/// exception, which Swift cannot catch, when it finds no plist, an app id it cannot read, an API key that is not of the
/// shape its Installations demands, or no project id or sender id, so the app starts it only from a plist this guard
/// accepts. Anything else is "the gate stays open", never a crash.
struct FirebasePlistCheckTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FirebasePlistCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aPlistWithTheFourKeysIsUsable() {
        #expect(FirebasePlistCheck.problem(in: goodPlist) == nil)
    }

    @Test func noPlistIsNotUsable() {
        #expect(FirebasePlistCheck.problem(in: nil) != nil)
    }

    @Test(arguments: unusableAppIDs)
    func badAppIdsAreNotUsable(appID: String?) {
        let plist = goodPlistWith("GOOGLE_APP_ID", appID)

        #expect(FirebasePlistCheck.problem(in: plist) != nil, "\(String(describing: appID)) is not an app id")
    }

    @Test func aNonStringAppIdIsNotUsable() {
        #expect(FirebasePlistCheck.problem(in: goodPlistWith("GOOGLE_APP_ID", 5)) != nil)
    }

    @Test(arguments: unusableAPIKeys)
    func badAPIKeysAreNotUsable(apiKey: String?) {
        let plist = goodPlistWith("API_KEY", apiKey)

        #expect(FirebasePlistCheck.problem(in: plist) != nil, "\(String(describing: apiKey)) is not an API key")
    }

    @Test func aRealShapedAPIKeyIsUsable() {
        let realShape = "AIza" + String(repeating: "x", count: 35)

        #expect(FirebasePlistCheck.problem(in: goodPlistWith("API_KEY", realShape)) == nil)
    }

    @Test func aNonStringAPIKeyIsNotUsable() {
        #expect(FirebasePlistCheck.problem(in: goodPlistWith("API_KEY", 5)) != nil)
    }

    /// The project id and the sender id, which Installations and Remote Config raise without, must be there and be text.
    @Test(arguments: ["PROJECT_ID", "GCM_SENDER_ID"])
    func aMissingBlankOrNonTextValueIsNotUsable(key: String) {
        let unusable: [Any?] = [nil, "", "   ", "\n", 5]

        for value in unusable {
            let plist = goodPlistWith(key, value)

            #expect(FirebasePlistCheck.problem(in: plist) != nil, "\(key) = \(String(describing: value))")
        }
    }

    @Test func thePlistIsReadFromAFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let valid = folder.appendingPathComponent("valid.plist")
        try PropertyListSerialization.data(fromPropertyList: goodPlist, format: .xml, options: 0).write(to: valid)
        let garbage = folder.appendingPathComponent("garbage.plist")
        try Data([0x00, 0xFF, 0x10, 0x42, 0x13]).write(to: garbage)
        let array = folder.appendingPathComponent("array.plist")
        try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0).write(to: array)

        #expect(FirebasePlistCheck.plist(atPath: valid.path)?["GOOGLE_APP_ID"] as? String == goodAppID)
        #expect(FirebasePlistCheck.problem(in: FirebasePlistCheck.plist(atPath: valid.path)) == nil)
        #expect(FirebasePlistCheck.plist(atPath: folder.appendingPathComponent("missing.plist").path) == nil)
        #expect(FirebasePlistCheck.plist(atPath: nil) == nil)
        #expect(FirebasePlistCheck.plist(atPath: garbage.path) == nil, "bytes that are no plist")
        #expect(FirebasePlistCheck.plist(atPath: array.path) == nil, "a plist whose root is not a dictionary")
    }

    /// The reason is logged, so it must not carry anything of the file, whichever key it blames.
    @Test func theReasonNeverHoldsThePlistsValues() throws {
        let leaking: [[String: Any]] = [
            goodPlistWith("GOOGLE_APP_ID", "1:123456789012:android:abc"),
            goodPlistWith("API_KEY", "ASECRET-VALUE-THAT-MUST-NOT-LEAK"),
            goodPlistWith("PROJECT_ID", ""),
            goodPlistWith("GCM_SENDER_ID", "   "),
        ]
        let values = ["123456789012", "android", "ASECRET", "fixture-not-a-project", "000000000000", goodAPIKey]

        for plist in leaking {
            let reason = try #require(FirebasePlistCheck.problem(in: plist))

            for value in values {
                #expect(!reason.contains(value), "the reason holds \(value)")
            }
        }
    }
}
