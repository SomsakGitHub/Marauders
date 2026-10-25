import CryptoKit
import Foundation
import AVFoundation

enum ThaiAudioCacheError: Error { case http(Int) }

protocol ThaiAudioCaching: Sendable {
    func lookup(videoID: UUID, sourceURL: URL) async throws -> URL?
    func store(videoID: UUID, sourceURL: URL, audio: Data) async throws
}

struct ThaiAudioCacheClient: ThaiAudioCaching {
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
    }
    private func request(_ id: UUID, source: URL) throws -> URLRequest {
        let base = try APIConfiguration.apiBaseURL()
        var request = URLRequest(url: base.appending(path: "v1/videos/\(id.uuidString.lowercased())/thai-audio"))
        if let bearer = authorization.bearerAuthorizationHeader() { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    func lookup(videoID: UUID, sourceURL: URL) async throws -> URL? {
        let hash = Self.sourceHash(sourceURL)
        var request = try request(videoID, source: sourceURL)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "source", value: hash)]
        request.url = components.url
        request.timeoutInterval = 10
        let response = try await client.data(request)
        guard response.statusCode == 200 else { throw ThaiAudioCacheError.http(response.statusCode) }
        let reply = try JSONDecoder().decode(Reply.self, from: response.data)
        guard reply.sourceHash == hash else { throw ThaiDubbingError.failed }
        if reply.status == "missing" { return nil }
        guard reply.status == "ready", let audio = reply.audioURL,
              audio.scheme == "https", audio.host == request.url?.host,
              audio.user == nil, audio.password == nil,
              audio.path == "/v1/media/translations/\(videoID.uuidString.lowercased())/\(hash)-th-v1.m4a" else { throw ThaiDubbingError.failed }
        return audio
    }
    func store(videoID: UUID, sourceURL: URL, audio: Data) async throws {
        guard !audio.isEmpty, audio.count <= 4 * 1024 * 1024 else { throw ThaiDubbingError.failed }
        var request = try request(videoID, source: sourceURL)
        guard request.value(forHTTPHeaderField: "Authorization") != nil else { throw ThaiDubbingError.failed }
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.sourceHash(sourceURL), forHTTPHeaderField: "X-Source-SHA256")
        request.httpBody = audio
        let response = try await client.data(request)
        guard response.statusCode == 200 || response.statusCode == 201 else { throw ThaiAudioCacheError.http(response.statusCode) }
        let reply = try JSONDecoder().decode(Reply.self, from: response.data)
        guard reply.status == "ready", reply.sourceHash == Self.sourceHash(sourceURL) else { throw ThaiDubbingError.failed }
    }
}

nonisolated enum ThaiAudioCacheEncoding {
    @concurrent static func encode(source: URL, destination: URL) async throws -> Data {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw ThaiDubbingError.failed }
        try await export.export(to: destination, as: .m4a)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4 * 1024 * 1024 else { throw ThaiDubbingError.failed }
        return try Data(contentsOf: destination)
    }
}
