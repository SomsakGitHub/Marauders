//
//  AccountDeletionError.swift
//  Marauders
//

import Foundation

/// Why deleting the account did not happen, in the words the person is shown. The statuses are those of the Worker's
/// `DELETE /v1/users/me`.
enum AccountDeletionError: LocalizedError, Equatable {
    /// 401: the session is over, so the person signs in again.
    case signInRequired
    /// 400: Apple did not accept the confirmation (a code that ran out or was used already); they confirm again.
    case appleNotConfirmed
    /// 403: the Apple ID that confirmed is not the one this account was made with.
    case wrongAppleAccount
    /// 409: more clips than one deletion takes; they delete some from their Profile first.
    case tooManyClips(limit: Int)
    /// 429: too many attempts within the hour.
    case rateLimited
    /// 503 (the Worker has no Apple key to revoke with) and 405 (a Worker that does not have the route yet).
    case notAvailable
    /// Anything else the Worker answered.
    case couldNotFinish

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return String(localized: "Your session has ended. Please sign in again.")
        case .appleNotConfirmed:
            return String(localized: "Apple couldn't confirm it's you. Please try again.")
        case .wrongAppleAccount:
            return String(localized: "That isn't the Apple ID you signed in with.")
        case .tooManyClips(let limit):
            return String(
                localized: "You have more than \(limit) clips. Delete some from your Profile first, then try again.")
        case .rateLimited:
            return String(localized: "Too many attempts. Please try again later.")
        case .notAvailable:
            return String(localized: "Account deletion isn't available right now. Please try again later.")
        case .couldNotFinish:
            return String(localized: "We couldn't finish deleting your account. Please try again.")
        }
    }
}
