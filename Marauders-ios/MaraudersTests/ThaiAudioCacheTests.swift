import AVFoundation
import Foundation
import Testing
@testable import Marauders

@MainActor
struct ThaiAudioCacheTests {
    private struct Authorization: APIAuthorization {
        func bearerAuthorizationHeader() -> String? { "Bearer fixture-session" }
    }
    private actor HTTP: HTTPClient {
        private(set) var requests: [URLRequest] = []
        let body: Data
        init(_ body: String) { self.body = Data(body.utf8) }
        func data(_ request: URLRequest) async throws -> HTTPClientResponse { requests.append(request); return .init(data: body, statusCode: 200) }
        func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse { throw HTTPClientError.invalidResponse }
    }
    @Test func cacheHitHasExactClipRevisionAndUploadUsesSession() async throws {
        let id = UUID()
        let source = URL(string: "https://example.com/video.mp4")!
        let hash = ThaiAudioCacheClient.sourceHash(source)
        let base = try APIConfiguration.apiBaseURL()
        let audio = base.appending(path: "v1/media/translations/\(id.uuidString.lowercased())/\(hash)-th-v1.m4a")
        let http = HTTP("{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"\(audio.absoluteString)\"}")
        let api = ThaiAudioCacheClient(client: http, authorization: Authorization())
        #expect(try await api.lookup(videoID: id, sourceURL: source) == audio)
        try await api.store(videoID: id, sourceURL: source, audio: Data([1,2,3]))
        let requests = await http.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == hash)
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].httpBody == Data([1,2,3]))
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-session")
        #expect(requests[1].value(forHTTPHeaderField: "X-Source-SHA256") == hash)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
    }
    @Test func rejectsCrossOriginOrWrongRevisionAudio() async {
        let source = URL(string: "https://example.com/video.mp4")!
        let hash = ThaiAudioCacheClient.sourceHash(source)
        for body in [
            "{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"https://untrusted.example/audio.m4a\"}",
            "{\"status\":\"missing\",\"sourceHash\":\"wrong-revision\"}"
        ] {
            let api = ThaiAudioCacheClient(client: HTTP(body), authorization: NoAPIAuthorization())
            do { _ = try await api.lookup(videoID: UUID(), sourceURL: source); Issue.record("Accepted invalid cached audio") }
            catch { #expect(error is ThaiDubbingError) }
        }
    }
    @Test func guestCannotUploadSharedAudio() async {
        let http = HTTP("{}")
        let api = ThaiAudioCacheClient(client: http, authorization: NoAPIAuthorization())
        do { try await api.store(videoID: UUID(), sourceURL: URL(string: "https://example.com/v.mp4")!, audio: Data([1])); Issue.record("Guest upload accepted") }
        catch { #expect(await http.requests.isEmpty) }
    }
    @Test func deselectingThaiDiscardsLateCacheResponse() async {
        actor DeferredCache: ThaiAudioCaching {
            var continuation: CheckedContinuation<URL?, Never>?
            var started: CheckedContinuation<Void, Never>?
            func lookup(videoID: UUID, sourceURL: URL) async throws -> URL? {
                await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
            }
            func store(videoID: UUID, sourceURL: URL, audio: Data) async throws {}
            func wait() async { if continuation != nil { return }; await withCheckedContinuation { started = $0 } }
            func finish() { continuation?.resume(returning: nil); continuation = nil }
        }
        let cache = DeferredCache()
        let model = ThaiDubbingViewModel(cache: cache)
        let pending = Task { await model.cachedAudio(videoID: UUID(), sourceURL: URL(string: "https://example.com/v.mp4")!) }
        await cache.wait()
        model.useOriginal()
        await cache.finish()
        #expect(await pending.value == nil)
        #expect(model.message == nil)
        #expect(!model.isProcessing)
    }
    @Test func cachedAudioWorksWithoutCreatingTranslationSession() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try SpeechAudioPreparation.wave(Data(repeating: 0, count: 32000)).write(to: file)
        actor Cache: ThaiAudioCaching {
            let url: URL
            init(_ url: URL) { self.url = url }
            func lookup(videoID: UUID, sourceURL: URL) async throws -> URL? { url }
            func store(videoID: UUID, sourceURL: URL, audio: Data) async throws { Issue.record("Cache hit should not be uploaded again") }
        }
        let model = ThaiDubbingViewModel(cache: Cache(file))
        #expect(await model.cachedAudio(videoID: UUID(), sourceURL: URL(string: "https://example.com/v.mp4")!) == file)
        #expect(model.message?.contains("ใช้เสียงที่เก็บไว้") == true)
        #expect(!model.isProcessing)
        model.useOriginal()
    }
}
