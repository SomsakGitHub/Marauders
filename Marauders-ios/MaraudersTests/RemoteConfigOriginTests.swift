import Foundation
import Testing

@testable import Marauders

/// Where an answer of the Firebase SDK came from, as the log says it (docs/adr/012-force-update.md). The SDK asks Google
/// at most once an hour and answers from what it saved in between, and both end in a success, so only the SDK's own
/// "last fetch" time, which moves when Google answers and not otherwise, tells them apart.
struct RemoteConfigOriginTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// How the SDK says "never": the epoch, a date and not nil.
    private let never = Date(timeIntervalSince1970: 0)

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    // MARK: Judged by the last fetch time before and after the fetch

    @Test func aLastFetchTimeThatMovedMeansGoogleWasAsked() {
        let befores: [Date?] = [nil, never, ago(900)]
        for before in befores {
            let verdict = RemoteConfigOrigin.judge(lastFetchBefore: before, lastFetchAfter: now)
            #expect(verdict == .google, "from \(String(describing: before))")
        }
    }

    @Test func aLastFetchTimeThatStayedMeansTheSavedValuesAnswered() {
        let verdict = RemoteConfigOrigin.judge(lastFetchBefore: ago(900), lastFetchAfter: ago(900))

        #expect(verdict == .saved(lastAsked: ago(900)))
    }

    /// Nil and the epoch are the same "never", so neither spelling is a move.
    @Test func neverAskedIsTheSameWhetherTheSdkSaysNilOrTheEpoch() {
        let pairs: [(Date?, Date?)] = [(nil, never), (never, nil), (never, never), (nil, nil)]
        for (before, after) in pairs {
            let verdict = RemoteConfigOrigin.judge(lastFetchBefore: before, lastFetchAfter: after)
            let pair = "\(String(describing: before)) then \(String(describing: after))"
            #expect(verdict == .saved(lastAsked: nil), "\(pair)")
        }
    }

    // MARK: What the log says

    @Test func googleIsSaidPlainly() {
        #expect(RemoteConfigOrigin.google.logText(now: now) == "from Google")
    }

    /// A clock set back makes the last ask lie in the future: that reads as 0 s, never as a negative age.
    @Test(arguments: [
        (0.0, "0 s"), (59.0, "59 s"), (60.0, "1 min"), (840.0, "14 min"), (3599.0, "59 min"), (3600.0, "1 h 0 min"),
        (5400.0, "1 h 30 min"), (-30.0, "0 s"),
    ])
    func theSavedAnswerSaysHowLongAgoGoogleWasAsked(seconds: Double, age: String) {
        let text = RemoteConfigOrigin.saved(lastAsked: ago(seconds)).logText(now: now)

        #expect(text == "from the SDK's saved values, Google last asked \(age) ago")
    }

    @Test func aSavedAnswerWithNoLastAskSaysSo() {
        let text = RemoteConfigOrigin.saved(lastAsked: nil).logText(now: now)

        #expect(text == "from the SDK's saved values, last ask unknown")
    }
}
