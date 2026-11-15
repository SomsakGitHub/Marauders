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
        switch await TimeBoundedCall.run(timeout: timeout, { _ = try await repository.setSharing(false) }) {
        case .finished:
            return .switchedOff
        case .failed(let reason):
            return .failed(reason: reason)
        case .timedOut:
            return .timedOut
        }
    }
}
