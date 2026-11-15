//
//  VideoUploadForm.swift
//  Marauders
//

import Foundation

/// The form of `POST /v1/videos`, shared by the two ways the app sends a clip: the foreground `VideoUploadAPIClient` and
/// the background uploader. What a clip must be to go out, the parts of the form, the request that carries them, and how
/// the Worker's answer is read are the same for both, so they are written once, here.
///
/// nonisolated, so the background uploader can use the form off the main actor. Only `request` stays on the main actor:
/// it reads `APIConfiguration`, which logs through the main-actor `AppLog`.
nonisolated enum VideoUploadForm {
    /// The Worker's limit for one clip: 100 MiB.
    static let maxUploadBytes: Int64 = 100 * 1024 * 1024

    /// The size of the clip at `fileURL` in bytes, once the clip is known to be fit to upload: an MP4 or a QuickTime
    /// movie that is not empty and not over `maxUploadBytes`. The type is judged first, before the file is looked at.
    ///
    /// - Throws: `VideoUploadAPIError.unsupportedFormat`, `VideoUploadAPIError.fileTooLarge` (also for an empty file), or
    ///   the file system's own error when the file cannot be read.
    static func validatedSize(of fileURL: URL, mimeType: String) throws -> Int64 {
        guard mimeType == "video/mp4" || mimeType == "video/quicktime" else {
            throw VideoUploadAPIError.unsupportedFormat
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0, fileSize <= maxUploadBytes else {
            throw VideoUploadAPIError.fileTooLarge
        }
        return fileSize
    }

    /// The parts of the form, in the order the Worker is sent them: the clip's latitude and longitude, the speech check
    /// when there is one, the trimmed caption when it is not empty, and the clip itself last.
    static func parts(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String,
        audioAssessment: ClipAudioAssessment?
    ) -> [HTTPMultipartPart] {
        var parts: [HTTPMultipartPart] = [
            .field(name: "latitude", value: String(clipLocation.latitude)),
            .field(name: "longitude", value: String(clipLocation.longitude)),
        ]
        if let audioAssessment, let data = try? JSONEncoder().encode(audioAssessment),
            let json = String(data: data, encoding: .utf8)
        {
            parts.append(.field(name: "audioAssessment", value: json))
        }
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            parts.append(.field(name: "caption", value: trimmedCaption))
        }
        // The clip is copied from disk into the body when the body is written, never read into memory here.
        parts.append(.fileAt(name: "file", filename: fileURL.lastPathComponent, mimeType: mimeType, url: fileURL))
        return parts
    }

    /// The request that carries the form: a POST to the Worker's upload URL with the bearer and a timeout of 300 seconds.
    ///
    /// - Parameters:
    ///   - boundary: The boundary of a multipart body that is written ahead of the request, as the background uploader
    ///     does. Without one the request has no `Content-Type`, because the HTTP client sets it, with a boundary of its
    ///     own, when it writes the body.
    ///   - idempotencyKey: Lets the Worker know a repeat of an upload from the first one, so it answers with the clip it
    ///     already stored instead of making a second one. Sent in lower case, as the Worker keeps it.
    @MainActor
    static func request(
        authorizationHeader: String,
        boundary: String? = nil,
        idempotencyKey: UUID? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try APIConfiguration.videoUploadURL())
        request.httpMethod = "POST"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        if let boundary {
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }
        request.timeoutInterval = 300
        return request
    }

    /// The clip a successful answer holds.
    ///
    /// - Throws: `VideoUploadAPIError.invalidResponse` when the body is not an upload answer or the clip's stream URL
    ///   is not HTTPS.
    static func decodeItem(from data: Data) throws -> FeedVideo {
        do {
            let decoded = try JSONDecoder().decode(VideoUploadAPIResponse.self, from: data)
            guard decoded.item.streamURL.scheme?.lowercased() == "https" else {
                throw VideoUploadAPIError.invalidResponse
            }
            return decoded.item
        } catch {
            throw VideoUploadAPIError.invalidResponse
        }
    }

    /// The text of the `error` field of the Worker's answer to a refused upload; nil when the body has none.
    static func serverMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            let error: String
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }
}
