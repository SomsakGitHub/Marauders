//
//  APIAuthorization.swift
//  Marauders
//

import Foundation
import MaraudersAuth

protocol APIAuthorization: Sendable {
    func bearerAuthorizationHeader() -> String?
}

struct NoAPIAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? { nil }
}

struct SessionAPIAuthorization: APIAuthorization {
    private let tokenStore: APIAccessTokenStore

    init(tokenStore: APIAccessTokenStore) {
        self.tokenStore = tokenStore
    }

    func bearerAuthorizationHeader() -> String? {
        guard let token = tokenStore.loadAccessToken(),
            APIAccessTokenFormat.isValid(token)
        else {
            return nil
        }
        return "Bearer \(token)"
    }
}
