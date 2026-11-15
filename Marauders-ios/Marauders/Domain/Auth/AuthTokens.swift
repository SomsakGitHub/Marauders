//
//  AuthTokens.swift
//  Marauders
//

import Foundation

/// What the Worker hands out when it opens or renews a session: the access token every request carries and, for a
/// client that asked for one at sign-in, the refresh token that buys the next pair. A Worker that does not know refresh
/// tokens answers with the access token alone, so `refreshToken` can be absent.
struct AuthTokens: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
}
