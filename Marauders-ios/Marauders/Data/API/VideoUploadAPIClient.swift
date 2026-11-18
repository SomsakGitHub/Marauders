//
//  VideoUploadAPIClient.swift
//  Marauders
//

import Foundation

nonisolated struct VideoUploadAPIResponse: Decodable, Sendable {
    let item: FeedVideo
}

nonisolated enum VideoUploadAPIError: LocalizedError, Equatable {
    case fileTooLarge
    case unsupportedFormat
    case notAuthenticated
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return String(localized: "Video must be 100 MB or smaller")
        case .unsupportedFormat:
            return String(localized: "Only MP4 / MOV is supported")
        case .notAuthenticated:
            return String(localized: "Sign in required to upload")
        case .serverError(let code):
            return String(localized: "Upload failed (status \(code))")
        case .invalidResponse:
            return String(localized: "Invalid server response")
        }
    }
}

struct VideoUploadAPIClient: Sendable {
    static let maxUploadBytes: Int64 = VideoUploadForm.maxUploadBytes

    private let client: HTTPClient
    private let authorization: APIAuthorization?

    nonisolated init(session: URLSession = .shared, authorization: APIAuthorization? = nil) {
        self.init(client: URLSessionHTTPClient(session: session), authorization: authorization)
    }

    nonisolated init(client: HTTPClient, authorization: APIAuthorization? = nil) {
        self.client = client
        self.authorization = authorization
    }

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String = "",
        audioAssessment: ClipAudioAssessment? = nil,
        progress: UploadProgressHandler? = nil
    ) async throws -> FeedVideo {
        // The form is nonisolated and cannot log, so the two refusals are logged here.
        let fileSize: Int64
        do {
            fileSize = try VideoUploadForm.validatedSize(of: fileURL, mimeType: mimeType)
        } catch VideoUploadAPIError.unsupportedFormat {
            AppLog.error("api.upload", "unsupported mime=\(mimeType)")
            throw VideoUploadAPIError.unsupportedFormat
        } catch VideoUploadAPIError.fileTooLarge {
            AppLog.error("api.upload", "file size invalid")
            throw VideoUploadAPIError.fileTooLarge
        }

        guard let authHeader = authorization?.bearerAuthorizationHeader() else {
            AppLog.warning("api.upload", "missing bearer token")
            throw VideoUploadAPIError.notAuthenticated
        }

        let request = try VideoUploadForm.request(authorizationHeader: authHeader)
        AppLog.info("api.upload", "POST \(request.url?.host ?? "?")/v1/videos bytes=\(fileSize)")

        let parts = VideoUploadForm.parts(
            fileURL: fileURL,
            mimeType: mimeType,
            clipLocation: clipLocation,
            caption: caption,
            audioAssessment: audioAssessment
        )

        let response = try await client.upload(request, multipart: parts, progress: progress)

        let bodySnippet = Self.snippet(from: response.data)
        AppLog.info("api.upload", "response status=\(response.statusCode) body=\(bodySnippet)")

        guard response.isSuccess else {
            if let serverMessage = VideoUploadForm.serverMessage(from: response.data) {
                throw UploadErrorMessage(message: serverMessage)
            }
            throw VideoUploadAPIError.serverError(response.statusCode)
        }

        do {
            let item = try VideoUploadForm.decodeItem(from: response.data)
            AppLog.info("api.upload", "decoded item id=\(item.id.uuidString)")
            return item
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
}

private struct UploadErrorMessage: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
