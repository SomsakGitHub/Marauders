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
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Video must be 100 MB or smaller"
        case .unsupportedFormat:
            return "Only MP4 / MOV is supported"
        case .serverError(let code):
            return "Upload failed (status \(code))"
        case .invalidResponse:
            return "Invalid server response"
        }
    }
}

struct VideoUploadAPIClient: Sendable {
    static let maxUploadBytes: Int64 = 100 * 1024 * 1024

    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation
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

        let requestURL = try APIConfiguration.videoUploadURL()
        AppLog.info("api.upload", "POST \(requestURL.host ?? "?")/v1/videos bytes=\(fileSize)")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let bodyURL = try writeMultipartBody(
            boundary: boundary,
            fileURL: fileURL,
            mimeType: mimeType,
            clipLocation: clipLocation
        )

        let bodySize = (try? FileManager.default.attributesOfItem(atPath: bodyURL.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        AppLog.info("api.upload", "multipart body bytes=\(bodySize)")

        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        try? FileManager.default.removeItem(at: bodyURL)

        guard let http = response as? HTTPURLResponse else {
            AppLog.error("api.upload", "no HTTPURLResponse")
            throw VideoUploadAPIError.invalidResponse
        }

        let bodySnippet = Self.snippet(from: data)
        AppLog.info("api.upload", "response status=\(http.statusCode) body=\(bodySnippet)")

        guard (200 ... 299).contains(http.statusCode) else {
            if let serverMessage = parseServerErrorMessage(from: data) {
                throw UploadErrorMessage(message: serverMessage)
            }
            throw VideoUploadAPIError.serverError(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(VideoUploadAPIResponse.self, from: data)
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

    private func writeMultipartBody(
        boundary: String,
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation
    ) throws -> URL {
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        var body = Data()

        body.appendFormField(
            boundary: boundary,
            name: "latitude",
            value: String(clipLocation.latitude)
        )
        body.appendFormField(
            boundary: boundary,
            name: "longitude",
            value: String(clipLocation.longitude)
        )

        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
        )
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
            .appendingPathExtension("multipart")
        try body.write(to: tempURL, options: .atomic)
        return tempURL
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

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendFormField(boundary: String, name: String, value: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }
}
