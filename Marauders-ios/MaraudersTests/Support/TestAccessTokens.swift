//
//  TestAccessTokens.swift
//  MaraudersTests
//

import Foundation

/// Builds access tokens shaped like the Worker's (`header.payload.signature`, base64url without padding).
/// The signature is a placeholder: the device never checks it.
enum TestAccessToken {
    /// A token carrying exactly these claims.
    static func make(claims: [String: Any]) -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data()
        return make(payload: payload)
    }

    /// A token whose payload is exactly these bytes, valid JSON or not.
    static func make(payload: Data) -> String {
        let header = base64URL(Data(#"{"alg":"HS256"}"#.utf8))
        return "\(header).\(base64URL(payload)).\(base64URL(Data("signature".utf8)))"
    }

    /// A token that expires `seconds` from now; a negative value is a token that expired that long ago.
    static func make(subject: String = "user-1", expiresIn seconds: TimeInterval) -> String {
        let issuedAt = Int(Date().timeIntervalSince1970)
        return make(claims: ["sub": subject, "iat": issuedAt, "exp": issuedAt + Int(seconds)])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
