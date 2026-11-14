//
//  LocationSharingAPIClient.swift
//  Marauders
//

import Foundation

struct LocationSharingAPIClient: Sendable {
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: URLSessionHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    /// GET: whether the viewer shares, and where the mutual followers who share were last.
    func friendLocations() async throws -> FriendLocations {
        let requestURL = try APIConfiguration.friendLocationsURL()
        AppLog.info("api.friends", "GET \(requestURL.host ?? "?")/v1/users/me/friend-locations")
        let response = try await send(requestURL, method: "GET", body: nil)
        do {
            let decoded = try JSONDecoder().decode(FriendLocationsResponse.self, from: response.data)
            return FriendLocations(
                sharing: decoded.sharing,
                located: decoded.located ?? true,
                friends: decoded.items.compactMap(\.location)
            )
        } catch {
            AppLog.error("api.friends", "decode failed: \(error.localizedDescription)")
            throw LocationSharingError.invalidResponse
        }
    }

    /// PUT: turns the viewer's sharing on or off; answers what the Worker stored.
    func setSharing(_ enabled: Bool) async throws -> Bool {
        let requestURL = try APIConfiguration.locationSharingURL()
        AppLog.info("api.friends", "PUT \(requestURL.host ?? "?")/v1/users/me/location-sharing")
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        let response = try await send(requestURL, method: "PUT", body: body)
        struct SharingResponse: Decodable { let sharesLocation: Bool }
        do {
            return try JSONDecoder().decode(SharingResponse.self, from: response.data).sharesLocation
        } catch {
            AppLog.error("api.friends", "decode failed: \(error.localizedDescription)")
            throw LocationSharingError.invalidResponse
        }
    }

    private func send(_ url: URL, method: String, body: Data?) async throws -> HTTPClientResponse {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw LocationSharingError.signInRequired
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = 15

        let response = try await client.data(request)
        switch response.statusCode {
        case 401:
            throw LocationSharingError.signInRequired
        case 429:
            throw LocationSharingError.rateLimited
        case 200...299:
            return response
        default:
            throw LocationSharingError.serverError(response.statusCode)
        }
    }

    private struct FriendLocationsResponse: Decodable {
        let sharing: Bool
        let located: Bool?
        let items: [Item]

        struct Item: Decodable {
            let handle: String
            let avatarURL: URL?
            let latitude: Double
            let longitude: Double
            let locationUpdatedAt: String?

            /// Nil for a point that is not on Earth, which the map could not place.
            var location: FriendLocation? {
                guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
                return FriendLocation(
                    handle: handle,
                    avatarURL: avatarURL,
                    latitude: latitude,
                    longitude: longitude,
                    updatedAt: locationUpdatedAt.flatMap(WorkerDateParser.date(from:))
                )
            }
        }
    }
}
