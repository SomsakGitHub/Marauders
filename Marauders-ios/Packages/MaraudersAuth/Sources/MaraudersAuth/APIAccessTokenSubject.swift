//
//  APIAccessTokenSubject.swift
//  Marauders
//

import Foundation

/// Reads the `sub` claim of the Worker's access token: the account the session belongs to.
///
/// Two tokens with the same subject are the same viewer's, whichever was issued first. That is what lets a request that
/// met a 401 take the token another request has already traded for, and never one that belongs to someone else.
public nonisolated enum APIAccessTokenSubject {
    /// The account the token was issued to, or nil when the token is not a JWT or has no usable `sub` (not a string, or
    /// empty). A caller that compares two subjects must hold both of them: two tokens that cannot be read are not known
    /// to be the same account's.
    public static func subject(of token: String) -> String? {
        guard let claims = APIAccessTokenPayload.claims(of: token, as: Claims.self), !claims.sub.isEmpty else {
            return nil
        }
        return claims.sub
    }

    private nonisolated struct Claims: Decodable {
        let sub: String
    }
}
