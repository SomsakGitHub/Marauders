//
//  IdempotentReplayResolver.swift
//  Marauders
//

import Foundation

/// Asks the Worker for the clip it stored under an upload's idempotency key, for a success whose answer never reached
/// the app.
///
/// The question is the upload's own request without its form: a POST to the upload URL with the key and the bearer. The
/// Worker answers it with the stored clip when it holds one under the key, and refuses it as an empty form otherwise.
/// Anything outside 2xx is a refusal and is never read as a clip.
nonisolated struct IdempotentReplayResolver: StoredUploadResolving {
    private let client: any HTTPClient

    init(client: any HTTPClient) {
        self.client = client
    }

    /// - Throws: `VideoUploadAPIError.serverError` for an answer outside 2xx, `VideoUploadAPIError.invalidResponse` for
    ///   a 2xx that holds no clip, and whatever the transport throws.
    func storedClip(forKey key: UUID, accessToken: String) async throws -> FeedVideo {
        let request = try await VideoUploadForm.request(
            authorizationHeader: "Bearer " + accessToken, idempotencyKey: key)
        let response = try await client.data(request)
        guard (200..<300).contains(response.statusCode) else {
            throw VideoUploadAPIError.serverError(response.statusCode)
        }
        return try VideoUploadForm.decodeItem(from: response.data)
    }
}
