import CryptoKit
import Foundation
import AVFoundation

enum DubbedAudioCacheError: Error { case http(Int) }

/// What the Worker did with a report about a saved AI audio file.
enum DubbedAudioReportOutcome: Equatable, Sendable {
    /// The report was recorded; the audio stays until enough other viewers report it too.
    case reported
    /// The audio was deleted, so the next viewer can save a replacement.
    case removed
    /// Nothing is saved for that clip and language, so there is nothing to report.
    case missing
}

protocol DubbedAudioCaching: Sendable {
    func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL?
    func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws
    /// The words the saved AI audio reads, for subtitles; nil when none were saved.
    func lookupText(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async -> String?
    func storeText(videoID: UUID, sourceURL: URL, language: ListeningLanguage, text: String) async throws
    /// Tells the Worker this saved AI audio is bad. Signed-in viewers only.
    func report(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> DubbedAudioReportOutcome
    /// Who is signed in, or nil for a guest. Guests cannot report, so they are not offered the button.
    var reporterID: String? { get }
}

extension DubbedAudioCaching {
    func lookupText(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async -> String? { nil }
    func storeText(videoID: UUID, sourceURL: URL, language: ListeningLanguage, text: String) async throws {}
    func report(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> DubbedAudioReportOutcome { throw DubbingError.failed }
    var reporterID: String? { nil }
}

struct DubbedAudioCacheClient: DubbedAudioCaching {
    private let client: any HTTPClient
    private let authorization: any APIAuthorization
    init(client: any HTTPClient = AlamofireHTTPClient(), authorization: any APIAuthorization = SessionAPIAuthorization(tokenStore: KeychainAPIAccessTokenStore())) {
        self.client = client; self.authorization = authorization
    }
    nonisolated static func sourceHash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private struct Reply: Decodable {
        let status: String
        let sourceHash: String
        let audioURL: URL?
        /// Absent in replies from Workers that predate listening languages.
        let language: String?
        let text: String?
    }
    private func request(_ id: UUID, language: ListeningLanguage, source: String? = nil, text: Bool = false) throws -> URLRequest {
        let base = try APIConfiguration.apiBaseURL()
        var components = URLComponents(url: base.appending(path: "v1/videos/\(id.uuidString.lowercased())/dubbed-audio"), resolvingAgainstBaseURL: false)!
        components.queryItems = (source.map { [URLQueryItem(name: "source", value: $0)] } ?? []) + [URLQueryItem(name: "lang", value: language.code)] + (text ? [URLQueryItem(name: "kind", value: "text")] : [])
        var request = URLRequest(url: components.url!)
        if let bearer = authorization.bearerAuthorizationHeader() { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL? {
        let hash = Self.sourceHash(sourceURL)
        var request = try request(videoID, language: language, source: hash)
        request.timeoutInterval = 10
        let response = try await client.data(request)
        guard response.statusCode == 200 else { throw DubbedAudioCacheError.http(response.statusCode) }
        let reply = try JSONDecoder().decode(Reply.self, from: response.data)
        guard reply.sourceHash == hash, reply.language == nil || reply.language == language.code else { throw DubbingError.failed }
        if reply.status == "missing" { return nil }
        guard reply.status == "ready", let audio = reply.audioURL,
              audio.scheme == "https", audio.host == request.url?.host,
              audio.user == nil, audio.password == nil,
              audio.path == "/v1/media/translations/\(videoID.uuidString.lowercased())/\(hash)-\(language.code)-v1.m4a" else { throw DubbingError.failed }
        return audio
    }
    func lookupText(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async -> String? {
        let hash = Self.sourceHash(sourceURL)
        guard var request = try? request(videoID, language: language, source: hash, text: true) else { return nil }
        request.timeoutInterval = 10
        guard let response = try? await client.data(request), response.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: response.data),
              reply.status == "ready", reply.sourceHash == hash, reply.language == nil || reply.language == language.code else { return nil }
        let text = reply.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
    func storeText(videoID: UUID, sourceURL: URL, language: ListeningLanguage, text: String) async throws {
        let body = Data(text.utf8)
        guard !body.isEmpty, body.count <= 16 * 1024 else { return }
        var request = try request(videoID, language: language, text: true)
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { throw DubbingError.failed }
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.sourceHash(sourceURL), forHTTPHeaderField: "X-Source-SHA256")
        request.httpBody = body
        let response = try await client.data(request)
        guard response.statusCode == 200 || response.statusCode == 201 else { throw DubbedAudioCacheError.http(response.statusCode) }
    }
    /// The signed-in user's id (the token's `sub`), or nil for a guest. Only used to keep one account's
    /// reports apart from another's on this iPhone; the Worker still checks the token itself.
    var reporterID: String? {
        guard let bearer = authorization.bearerAuthorizationHeader() else { return nil }
        let parts = bearer.split(separator: " ").last?.split(separator: ".") ?? []
        guard parts.count >= 2 else { return "signed-in" }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String, !sub.isEmpty else { return "signed-in" }
        return sub
    }
    private struct ReportReply: Decodable { let status: String }
    func report(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> DubbedAudioReportOutcome {
        let base = try APIConfiguration.apiBaseURL()
        var components = URLComponents(url: base.appending(path: "v1/videos/\(videoID.uuidString.lowercased())/dubbed-audio/report"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "lang", value: language.code)]
        var request = URLRequest(url: components.url!)
        guard let bearer = authorization.bearerAuthorizationHeader() else { throw DubbingError.failed }
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.sourceHash(sourceURL), forHTTPHeaderField: "X-Source-SHA256")
        let response = try await client.data(request)
        guard response.statusCode == 200 else { throw DubbedAudioCacheError.http(response.statusCode) }
        switch try JSONDecoder().decode(ReportReply.self, from: response.data).status {
        case "reported": return .reported
        case "removed": return .removed
        case "missing": return .missing
        default: throw DubbingError.failed
        }
    }
    func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws {
        guard !audio.isEmpty, audio.count <= 4 * 1024 * 1024 else { throw DubbingError.failed }
        var request = try request(videoID, language: language)
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { throw DubbingError.failed }
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.sourceHash(sourceURL), forHTTPHeaderField: "X-Source-SHA256")
        request.httpBody = audio
        let response = try await client.data(request)
        guard response.statusCode == 200 || response.statusCode == 201 else { throw DubbedAudioCacheError.http(response.statusCode) }
        let reply = try JSONDecoder().decode(Reply.self, from: response.data)
        guard reply.status == "ready", reply.sourceHash == Self.sourceHash(sourceURL),
              reply.language == nil || reply.language == language.code else { throw DubbingError.failed }
    }
}

nonisolated enum DubbedAudioCacheEncoding {
    @concurrent static func encode(source: URL, destination: URL) async throws -> Data {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw DubbingError.failed }
        try await export.export(to: destination, as: .m4a)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4 * 1024 * 1024 else { throw DubbingError.failed }
        return try Data(contentsOf: destination)
    }
}
