//
//  AuthRoute.swift
//  MaraudersAuthData
//

import Foundation

/// The Worker's auth routes. Each address is formed under the origin the app supplies.
enum AuthRoute: String {
    case apple = "v1/auth/apple"
    case refresh = "v1/auth/refresh"
    case signOut = "v1/auth/signout"
    case dev = "v1/auth/dev"

    func url(relativeTo base: URL) throws -> URL {
        guard let url = URL(string: rawValue, relativeTo: base) else { throw AuthRouteError.invalidBaseURL }
        return url
    }
}

/// A route could not be formed under the base URL. It cannot happen with the routes above; the message is the one the
/// app gives for a base URL it cannot use.
enum AuthRouteError: LocalizedError {
    case invalidBaseURL

    var errorDescription: String? { "API URL must be https:// with no path" }
}
