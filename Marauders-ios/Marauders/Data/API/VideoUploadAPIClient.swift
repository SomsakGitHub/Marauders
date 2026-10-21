//
//  VideoUploadAPIClient.swift
//  Marauders
//

import Foundation

struct VideoUploadAPIResponse: Decodable, Sendable {
    let item: FeedVideo
}

enum VideoUploadAPIError: LocalizedError, Equatable {
    case fileTooLarge
    case unsupportedFormat
    case notAuthenticated
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Video must be 100 MB or smaller"
        case .unsupportedFormat:
            return "Only MP4 / MOV is supported"
        case .notAuthenticated:
            return "Sign in required to upload"
        case .serverError(let code):
            return "Upload failed (status \(code))"
        case .invalidResponse:
            return "Invalid server response"
        }
    }
}

struct VideoUploadAPIClient: Sendable {
    static let maxUploadBytes: Int64 = 100 * 1024 * 1024

    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: AlamofireHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String = ""
    ) async throws -> FeedVideo {
        guard mimeType == "video/mp4" || mimeType == "video/quicktime" else {
            AppLog.error("api.upload", "unsupported mime=\(mimeType)")
            throw VideoUploadAPIError.unsupportedFormat
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0, fileSize <= Self.maxUploadBytes else {
            AppLog.error("api.upload", "file size invalid bytes=\(fileSize)")
            throw VideoUploadAPIError.fileTooLarge
        }

        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            AppLog.warning("api.upload", "missing bearer token")
            throw VideoUploadAPIError.notAuthenticated
        }

        let requestURL = try APIConfiguration.videoUploadURL()
        AppLog.info("api.upload", "POST \(requestURL.host ?? "?")/v1/videos bytes=\(fileSize)")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300

        let fileData = try Data(contentsOf: fileURL)
        let parts = multipartParts(
            fileName: fileURL.lastPathComponent,
            mimeType: mimeType,
            fileData: fileData,
            clipLocation: clipLocation,
            caption: caption
        )

        let response = try await client.upload(request, multipart: parts)

        let bodySnippet = Self.snippet(from: response.data)
        AppLog.info("api.upload", "response status=\(response.statusCode) body=\(bodySnippet)")

        guard response.isSuccess else {
            if let serverMessage = parseServerErrorMessage(from: response.data) {
                throw UploadErrorMessage(message: serverMessage)
            }
            throw VideoUploadAPIError.serverError(response.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(VideoUploadAPIResponse.self, from: response.data)
            guard decoded.item.streamURL.scheme?.lowercased() == "https" else {
                AppLog.error("api.upload", "stream URL not HTTPS")
                throw VideoUploadAPIError.invalidResponse
            }
            AppLog.info("api.upload", "decoded item id=\(decoded.item.id.uuidString)")
            return decoded.item
        } catch {
            AppLog.error("api.upload", "JSON decode failed: \(error.localizedDescription) body=\(bodySnippet)")
            throw VideoUploadAPIError.invalidResponse
        }
    }

    private static func snippet(from data: Data, limit: Int = 280) -> String {
        guard let text = String(data: data.prefix(limit), encoding: .utf8) else {
            return "<non-utf8 len=\(data.count)>"
        }
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    private func multipartParts(
        fileName: String,
        mimeType: String,
        fileData: Data,
        clipLocation: ClipLocation,
        caption: String
    ) -> [HTTPMultipartPart] {
        var parts: [HTTPMultipartPart] = [
            .field(name: "latitude", value: String(clipLocation.latitude)),
            .field(name: "longitude", value: String(clipLocation.longitude)),
        ]
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            parts.append(.field(name: "caption", value: trimmedCaption))
        }
        parts.append(.file(name: "file", filename: fileName, mimeType: mimeType, data: fileData))
        return parts
    }

    private func parseServerErrorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            let error: String
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }
}

private struct UploadErrorMessage: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
