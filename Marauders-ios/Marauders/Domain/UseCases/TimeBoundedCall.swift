//
//  TimeBoundedCall.swift
//  Marauders
//

import Foundation

/// Runs a call and gives up on it after `timeout`, so whoever waits for it is never held back longer than that.
enum TimeBoundedCall {
    enum Outcome<Value: Sendable>: Sendable {
        case finished(Value)
        /// The call went wrong; `reason` is for the log.
        case failed(reason: String)
        /// No answer within the timeout; the call was given up.
        case timedOut
    }

    /// The call and a timer race, and the caller goes on with whichever ends first. A task group would wait for the
    /// call too, however long a transport that ignores cancellation takes; this does not.
    static func run<Value: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Outcome<Value> {
        await withCheckedContinuation { continuation in
            let race = Race<Value>(continuation)
            race.call = Task {
                do {
                    race.finish(.finished(try await operation()))
                } catch {
                    race.finish(.failed(reason: error.localizedDescription))
                }
            }
            race.timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                race.finish(.timedOut)
            }
        }
    }
}

/// Hands the first outcome to the waiting caller and stops the other task, so neither outlives the answer: a call that
/// was given up is cancelled, and a timer that is no longer needed ends.
@MainActor
private final class Race<Value: Sendable> {
    private var continuation: CheckedContinuation<TimeBoundedCall.Outcome<Value>, Never>?
    var call: Task<Void, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<TimeBoundedCall.Outcome<Value>, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: TimeBoundedCall.Outcome<Value>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
        call?.cancel()
        timer?.cancel()
    }
}
