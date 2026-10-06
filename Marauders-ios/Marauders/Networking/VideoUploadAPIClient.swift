//
//  VideoUploadAPIClient.swift
//  Marauders
//

import Foundation

struct VideoUploadAPIResponse: Decodable, Sendable {
    let item: FeedVideo
}

enum VideoUploadAPIError: LocalizedError {
    case fileTooLarge
    case unsupportedFormat
    case invalidMetadata
    case serverError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "วิดีโอต้องไม่เกิน 100 MB"
        case .unsupportedFormat:
            return "รองรับเฉพาะ MP4 / MOV"
        case .invalidMetadata:
            return "กรอกข้อมูลไม่ครบหรือรูปแบบไม่ถูกต้อง"
        case .serverError(let code):
            return "อัปโหลดไม่สำเร็จ (รหัส \(code))"
        case .invalidResponse:
            return "ตอบกลับจากเซิร์ฟเวอร์ไม่ถูกต้อง"
        }
    }
}

struct VideoUploadAPIClient: Sendable {
    static let maxUploadBytes = 100 * 1024 * 1024

    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(
        fileURL: URL,
        mimeType: String,
        authorName: String,
        caption: String,
        musicTitle: String
    ) async throws -> FeedVideo {
        guard mimeType == "video/mp4" || mimeType == "video/quicktime" else {
            throw VideoUploadAPIError.unsupportedFormat
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 0, fileSize <= Self.maxUploadBytes else {
            throw VideoUploadAPIError.fileTooLarge
        }

        let trimmedAuthor = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMusic = musicTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            trimmedAuthor.range(of: #"^@[A-Za-z0-9._]{1,63}$"#, options: .regularExpression) != nil,
            (1 ... 500).contains(trimmedCaption.count),
            (1 ... 200).contains(trimmedMusic.count)
        else {
            throw VideoUploadAPIError.invalidMetadata
        }

        let requestURL = try APIConfiguration.videoUploadURL()
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let bodyURL = try writeMultipartBody(
            boundary: boundary,
            authorName: trimmedAuthor,
            caption: trimmedCaption,
            musicTitle: trimmedMusic,
            fileURL: fileURL,
            mimeType: mimeType
        )

        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        try? FileManager.default.removeItem(at: bodyURL)

        guard let http = response as? HTTPURLResponse else {
            throw VideoUploadAPIError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            throw VideoUploadAPIError.serverError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(VideoUploadAPIResponse.self, from: data)
        guard decoded.item.streamURL.scheme?.lowercased() == "https" else {
            throw VideoUploadAPIError.invalidResponse
        }
        return decoded.item
    }

    private func writeMultipartBody(
        boundary: String,
        authorName: String,
        caption: String,
        musicTitle: String,
        fileURL: URL,
        mimeType: String
    ) throws -> URL {
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        var body = Data()

        func appendField(name: String, value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        appendField(name: "authorName", value: authorName)
        appendField(name: "caption", value: caption)
        appendField(name: "musicTitle", value: musicTitle)

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
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
