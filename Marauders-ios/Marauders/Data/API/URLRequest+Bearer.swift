//
//  URLRequest+Bearer.swift
//  Marauders
//

import Foundation

extension URLRequest {
    /// The token of an `Authorization: Bearer …` header. Nil for a request without one (a guest, or the sign-in call
    /// itself) and for a header that holds no token after the scheme.
    nonisolated var bearerToken: String? {
        let scheme = "Bearer "
        guard let header = value(forHTTPHeaderField: "Authorization"), header.hasPrefix(scheme) else {
            return nil
        }
        let token = header.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
