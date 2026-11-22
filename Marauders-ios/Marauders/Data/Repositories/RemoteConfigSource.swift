//
//  RemoteConfigSource.swift
//  Marauders
//

import Foundation

/// Where the answer of one fetch came from, for the log (docs/adr/012-force-update.md). The SDK asks Google at most once
/// an hour and answers from what it saved in between, and both end in a success, so without this a log line cannot say
/// whether Google just answered 5 or the SDK still holds the 5 it got before the owner published 0.
nonisolated enum RemoteConfigOrigin: Equatable, Sendable {
    /// The SDK asked Google during this fetch.
    case google
    /// The SDK asked nothing and answered from what it saved. `lastAsked` is when Google was last asked; nil when never.
    case saved(lastAsked: Date?)

    /// Judged by the SDK's own "last fetch" time, read before and after the fetch: it moves when Google answered and
    /// stays when the SDK answered from what it saved. The SDK says "never" as the epoch, a date and not nil, so both
    /// spellings count as never.
    static func judge(lastFetchBefore: Date?, lastFetchAfter: Date?) -> RemoteConfigOrigin {
        guard let after = asked(lastFetchAfter) else {
            return .saved(lastAsked: nil)
        }
        return after == asked(lastFetchBefore) ? .saved(lastAsked: after) : .google
    }

    /// What the log adds to `config refreshed: minimumBuild=<n>`, after a space and in parentheses.
    func logText(now: Date) -> String {
        switch self {
        case .google:
            return "from Google"
        case .saved(let lastAsked?):
            return "from the SDK's saved values, Google last asked \(Self.age(since: lastAsked, now: now)) ago"
        case .saved(nil):
            return "from the SDK's saved values, last ask unknown"
        }
    }

    /// The time Google was asked, or nil for "never" (nil or the epoch).
    private static func asked(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 0 else {
            return nil
        }
        return date
    }

    /// `59 s`, `14 min`, `1 h 30 min`: whole units, rounded down. A clock set back puts the last ask in the future, which
    /// reads as 0 s and never as a negative age.
    private static func age(since lastAsked: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(lastAsked)))
        switch seconds {
        case ..<60:
            return "\(seconds) s"
        case ..<3600:
            return "\(seconds / 60) min"
        default:
            return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
        }
    }
}

/// The two numbers of the force-update gate as the owner published them in Firebase Remote Config, still as text
/// (`minimum_build` and `update_url`, docs/adr/012-force-update.md). A parameter that is not published reads as "".
struct RemoteConfigValues: Equatable, Sendable {
    let minimumBuild: String
    let updateURL: String
    /// Where the SDK got them, when the source can tell (a stand-in in a test says nothing): only the log reads it.
    let origin: RemoteConfigOrigin?

    nonisolated init(minimumBuild: String, updateURL: String, origin: RemoteConfigOrigin? = nil) {
        self.minimumBuild = minimumBuild
        self.updateURL = updateURL
        self.origin = origin
    }
}

/// Where `FirebaseAppConfigRepository` gets the two texts: the Firebase SDK in the app (`FirebaseRemoteConfigSource`),
/// a scripted stand-in in tests. It answers nil for every failure, a cancellation included, and nothing here throws, so
/// a failure can only ever leave what the repository kept as it was.
protocol RemoteConfigSource: Sendable {
    func fetch() async -> RemoteConfigValues?
}
