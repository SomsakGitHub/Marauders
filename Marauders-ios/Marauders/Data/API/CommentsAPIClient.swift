//
//  CommentsAPIClient.swift
//  Marauders
//

import Foundation

struct CommentsAPIClient: Sendable {
    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: AlamofireHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    /// Lists a clip's comments, newest first. Works signed out; a valid session only adds `canDelete`.
    func fetchComments(videoID: UUID, cursor: UUID? = nil, limit: Int = CommentRules.pageSize) async throws -> CommentPage {
        let requestURL = try APIConfiguration.commentsURL(videoID: videoID, limit: limit, cursor: cursor)
        AppLog.info("api.comments", "GET \(requestURL.host ?? "?")/v1/videos/<id>/comments")

        let bearer = authorization?.bearerAuthorizationHeader()
        var response = try await client.data(Self.listRequest(url: requestURL, bearer: bearer))
        if response.statusCode == 401, bearer != nil {
            // The Worker rejects a bad session even on reads, so read as a guest instead of failing.
            AppLog.warning("api.comments", "session rejected, reading as guest")
            response = try await client.data(Self.listRequest(url: requestURL, bearer: nil))
        }

        switch response.statusCode {
        case 404:
            throw CommentError.notFound
        case 200 ... 299:
            break
        default:
            throw CommentError.serverError(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(ListResponse.self, from: response.data)
            return CommentPage(items: try decoded.items.map { try $0.comment() }, nextCursor: decoded.nextCursor)
        } catch {
            AppLog.error("api.comments", "decode failed: \(error.localizedDescription)")
            throw CommentError.invalidResponse
        }
    }

    /// Adds a comment as the signed-in user and returns it as the Worker stored it.
    func postComment(videoID: UUID, body: String, language: String? = nil) async throws -> Comment {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw CommentError.signInRequired
        }

        let requestURL = try APIConfiguration.commentsURL(videoID: videoID)
        AppLog.info("api.comments", "POST \(requestURL.host ?? "?")/v1/videos/<id>/comments")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(CreateBody(body: body, language: language))

        let response = try await client.data(request)
        switch response.statusCode {
        case 401:
            throw CommentError.signInRequired
        case 404:
            throw CommentError.notFound
        case 400, 422:
            throw CommentError.invalidBody
        case 429:
            throw CommentError.rateLimited
        case 200 ... 299:
            break
        default:
            throw CommentError.serverError(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(CreateResponse.self, from: response.data).comment.comment()
        } catch {
            AppLog.error("api.comments", "decode failed: \(error.localizedDescription)")
            throw CommentError.invalidResponse
        }
    }

    /// Removes a comment the signed-in user wrote or that sits on a clip they own.
    func deleteComment(videoID: UUID, commentID: UUID) async throws {
        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            throw CommentError.signInRequired
        }

        let requestURL = try APIConfiguration.commentURL(videoID: videoID, commentID: commentID)
        AppLog.info("api.comments", "DELETE \(requestURL.host ?? "?")/v1/videos/<id>/comments/<id>")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let response = try await client.data(request)
        switch response.statusCode {
        case 401:
            throw CommentError.signInRequired
        case 404:
            throw CommentError.notFound
        case 200 ... 299:
            break
        default:
            throw CommentError.serverError(response.statusCode)
        }
    }

    private static func listRequest(url: URL, bearer: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15
        return request
    }

    private struct CreateBody: Encodable {
        let body: String
        let language: String?
    }

    private struct ListResponse: Decodable {
        let items: [CommentPayload]
        let nextCursor: UUID?
    }

    private struct CreateResponse: Decodable {
        let comment: CommentPayload
    }

    private struct CommentPayload: Decodable {
        let id: UUID
        let body: String
        let language: String?
        let createdAt: String
        let authorName: String?
        let authorAvatarURL: URL?
        let canDelete: Bool

        func comment() throws -> Comment {
            guard let date = CommentDateParser.date(from: createdAt) else {
                throw CommentError.invalidResponse
            }
            return Comment(
                id: id,
                body: body,
                language: language,
                createdAt: date,
                authorName: authorName,
                authorAvatarURL: authorAvatarURL,
                canDelete: canDelete
            )
        }
    }
}

/// The Worker writes `Date.toISOString()`, which carries milliseconds; `JSONDecoder.iso8601` rejects those.
private enum CommentDateParser {
    static func date(from string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
