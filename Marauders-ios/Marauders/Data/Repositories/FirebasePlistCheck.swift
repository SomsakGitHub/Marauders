//
//  FirebasePlistCheck.swift
//  Marauders
//

import Foundation

/// The guard before `FirebaseApp.configure(options:)` (docs/adr/012-force-update.md). The SDK raises an Objective-C
/// exception, which Swift cannot catch, when it finds no plist, and, while it starts, when the plist's app id is missing
/// or not of the shape `1:<project number>:ios:<hex>` (Core), when its API key is not 39 characters of an A followed by
/// letters, digits, `-` and `_` or its project id is missing (Installations), and when its sender id is missing (Remote
/// Config). A plist that gets past this check cannot do any of that, so the app starts Firebase only from one that does;
/// anything else leaves the gate open and the app running as it was. Found by the first run of the app with a fixture
/// plist, which crashed it: the app id was the only key this check used to read.
///
/// What this cannot see is a plist of another app: the SDK itself only logs that, so the shipped build is guarded by
/// `Scripts/check-firebase-plist.sh`, which the TestFlight lane runs, and not here.
///
/// nonisolated, like `BuildNumber`, so the fetch can run off the main actor.
nonisolated enum FirebasePlistCheck {
    /// The plist at `path` as a dictionary. Nil when there is no path, the file cannot be read, or its root is not a
    /// dictionary.
    static func plist(atPath path: String?) -> [String: Any]? {
        guard let path else {
            return nil
        }
        return NSDictionary(contentsOfFile: path) as? [String: Any]
    }

    /// Nil when the SDK can start from `plist`; otherwise why not, in words that hold nothing of the file (the reason
    /// is logged).
    static func problem(in plist: [String: Any]?) -> String? {
        guard let plist else {
            return "no usable GoogleService-Info.plist"
        }
        guard let appID = plist["GOOGLE_APP_ID"] as? String, isIosAppID(appID) else {
            return "GOOGLE_APP_ID is missing or malformed"
        }
        guard let apiKey = plist["API_KEY"] as? String, isAPIKey(apiKey) else {
            return "API_KEY is missing or malformed"
        }
        // The SDK reads these two as text and raises when they are empty, so a number or a blank is turned away too.
        guard let projectID = plist["PROJECT_ID"] as? String, isFilled(projectID) else {
            return "PROJECT_ID is missing"
        }
        guard let senderID = plist["GCM_SENDER_ID"] as? String, isFilled(senderID) else {
            return "GCM_SENDER_ID is missing"
        }
        return nil
    }

    /// What Installations demands of an API key: 39 characters, an A first, then letters, digits, `-` and `_`. Stricter
    /// than the SDK in one way, ASCII only, which every key from the console is.
    private static func isAPIKey(_ text: String) -> Bool {
        text.utf8.count == 39 && text.hasPrefix("A")
            && isNonEmpty(Substring(text), in: [0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D...0x2D, 0x5F...0x5F])
    }

    private static func isFilled(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `1:<digits>:ios:<hex digits>`, all of it: no space, no extra part, nothing but ASCII.
    private static func isIosAppID(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "1", parts[2] == "ios" else {
            return false
        }
        return isNonEmpty(parts[1], in: [0x30...0x39])
            && isNonEmpty(parts[3], in: [0x30...0x39, 0x41...0x46, 0x61...0x66])
    }

    private static func isNonEmpty(_ part: Substring, in ranges: [ClosedRange<UInt8>]) -> Bool {
        !part.isEmpty && part.utf8.allSatisfy { byte in ranges.contains { $0.contains(byte) } }
    }
}
