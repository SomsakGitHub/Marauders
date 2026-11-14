//
//  StopLocationSharingOnSignOutUseCase.swift
//  Marauders
//

import Foundation

/// Switches the viewer's location sharing off on the Worker as they sign out, so their last location stops showing on
/// their mutual followers' maps. Only a request that carries the session's token can do it, so a sign out runs this
/// before it clears the token.
///
/// Best effort: it never throws and never waits longer than `timeout`, so the sign out is never held back by it. A
/// token the Worker already rejected cannot make the call, and neither can a viewer who is offline: sharing then stays
/// on.
struct StopLocationSharingOnSignOutUseCase {
    enum Outcome: Equatable, Sendable {
        /// The Worker said sharing is off.
        case switchedOff
        /// The call went wrong; `reason` is for the log.
        case failed(reason: String)
        /// No answer within `timeout`; the call was given up.
        case timedOut
    }

    /// How long a sign out waits for the Worker.
    static let defaultTimeout: Duration = .seconds(3)

    private let repository: LocationSharingRepository
    private let timeout: Duration

    init(
        repository: LocationSharingRepository,
        timeout: Duration = StopLocationSharingOnSignOutUseCase.defaultTimeout
    ) {
        self.repository = repository
        self.timeout = timeout
    }

    func execute() async -> Outcome {
        let repository = repository
        let timeout = timeout
        // The call and the timer race, and the sign out goes on with whichever ends first. A task group would wait for
        // the call too, however long a transport that ignores cancellation takes; this does not.
        return await withCheckedContinuation { continuation in
            let race = Race(continuation)
            race.call = Task {
                do {
                    _ = try await repository.setSharing(false)
                    race.finish(.switchedOff)
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

/// Hands the first outcome to the waiting sign out and stops the other task, so neither outlives the answer: a call
/// that was given up is cancelled, and a timer that is no longer needed ends.
@MainActor
private final class Race {
    private var continuation: CheckedContinuation<StopLocationSharingOnSignOutUseCase.Outcome, Never>?
    var call: Task<Void, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<StopLocationSharingOnSignOutUseCase.Outcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: StopLocationSharingOnSignOutUseCase.Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
        call?.cancel()
        timer?.cancel()
    }
}
