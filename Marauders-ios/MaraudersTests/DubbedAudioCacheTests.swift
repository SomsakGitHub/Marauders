import AVFoundation
import Foundation
import Testing
@testable import Marauders

@MainActor
struct DubbedAudioCacheTests {
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
        let hash = DubbedAudioCacheClient.sourceHash(source)
        let base = try APIConfiguration.apiBaseURL()
        let audio = base.appending(path: "v1/media/translations/\(id.uuidString.lowercased())/\(hash)-th-v1.m4a")
        let http = HTTP("{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"\(audio.absoluteString)\"}")
        let api = DubbedAudioCacheClient(client: http, authorization: Authorization())
        #expect(try await api.lookup(videoID: id, sourceURL: source, language: .thai) == audio)
        try await api.store(videoID: id, sourceURL: source, language: .thai, audio: Data([1,2,3]))
        let requests = await http.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.path.hasSuffix("/dubbed-audio") == true)
        let lookupQuery = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(lookupQuery.first { $0.name == "source" }?.value == hash)
        #expect(lookupQuery.first { $0.name == "lang" }?.value == "th")
        #expect(requests[1].url?.path.hasSuffix("/dubbed-audio") == true)
        #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "lang" }?.value == "th")
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].httpBody == Data([1,2,3]))
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-session")
        #expect(requests[1].value(forHTTPHeaderField: "X-Source-SHA256") == hash)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
    }
    @Test func rejectsCrossOriginOrWrongRevisionAudio() async {
        let source = URL(string: "https://example.com/video.mp4")!
        let hash = DubbedAudioCacheClient.sourceHash(source)
        for body in [
            "{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"https://untrusted.example/audio.m4a\"}",
            "{\"status\":\"missing\",\"sourceHash\":\"wrong-revision\"}"
        ] {
            let api = DubbedAudioCacheClient(client: HTTP(body), authorization: NoAPIAuthorization())
            do { _ = try await api.lookup(videoID: UUID(), sourceURL: source, language: .thai); Issue.record("Accepted invalid cached audio") }
            catch { #expect(error is DubbingError) }
        }
    }
    @Test func guestCannotUploadSharedAudio() async {
        let http = HTTP("{}")
        let api = DubbedAudioCacheClient(client: http, authorization: NoAPIAuthorization())
        do { try await api.store(videoID: UUID(), sourceURL: URL(string: "https://example.com/v.mp4")!, language: .thai, audio: Data([1])); Issue.record("Guest upload accepted") }
        catch { #expect(await http.requests.isEmpty) }
    }
    @Test func deselectingDubbingDiscardsLateCacheResponse() async {
        actor DeferredCache: DubbedAudioCaching {
            var continuation: CheckedContinuation<URL?, Never>?
            var started: CheckedContinuation<Void, Never>?
            func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL? {
                await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
            }
            func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws {}
            func wait() async { if continuation != nil { return }; await withCheckedContinuation { started = $0 } }
            func finish() { continuation?.resume(returning: nil); continuation = nil }
        }
        let cache = DeferredCache()
        let model = DubbingViewModel(cache: cache, memo: DetectedLanguageMemo(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!))
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        let pending = Task { await model.prepare(clip: clip, target: .thai) }
        await cache.wait()
        model.useOriginal()
        await cache.finish()
        #expect(await pending.value == .unavailable)
        #expect(model.message == nil)
        #expect(!model.isProcessing)
    }
    @Test func cachedAudioWorksWithoutCreatingTranslationSession() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try SpeechAudioPreparation.wave(Data(repeating: 0, count: 32000)).write(to: file)
        actor Cache: DubbedAudioCaching {
            let url: URL
            init(_ url: URL) { self.url = url }
            func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL? { url }
            func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws { Issue.record("Cache hit should not be uploaded again") }
        }
        let model = DubbingViewModel(cache: Cache(file), memo: DetectedLanguageMemo(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!))
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/v.mp4")!)
        #expect(await model.prepare(clip: clip, target: .thai) == .cached(file))
        #expect(model.message == String(localized: "AI audio in \(ListeningLanguage.thai.sentenceName()) · using saved audio"))
        #expect(!model.isProcessing)
        model.useOriginal()
    }

    @Test func eachLanguageHasItsOwnRequestAndAudioPath() async throws {
        let id = UUID()
        let source = URL(string: "https://example.com/video.mp4")!
        let hash = DubbedAudioCacheClient.sourceHash(source)
        let base = try APIConfiguration.apiBaseURL()
        func audio(_ code: String) -> URL {
            base.appending(path: "v1/media/translations/\(id.uuidString.lowercased())/\(hash)-\(code)-v1.m4a")
        }
        let spanish = DubbedAudioCacheClient(
            client: HTTP("{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"\(audio("es").absoluteString)\",\"language\":\"es\"}"),
            authorization: Authorization())
        #expect(try await spanish.lookup(videoID: id, sourceURL: source, language: .spanish) == audio("es"))
        // The Thai file is never accepted for a Spanish request, whether the Worker tags it or not.
        for body in [
            "{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"\(audio("th").absoluteString)\",\"language\":\"th\"}",
            "{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"\(audio("th").absoluteString)\"}"
        ] {
            let api = DubbedAudioCacheClient(client: HTTP(body), authorization: Authorization())
            do { _ = try await api.lookup(videoID: id, sourceURL: source, language: .spanish); Issue.record("Accepted audio for another language") }
            catch { #expect(error is DubbingError) }
        }
    }

    @Test func serverReplyWithoutALanguageStillWorksForThai() async throws {
        let id = UUID()
        let source = URL(string: "https://example.com/video.mp4")!
        let hash = DubbedAudioCacheClient.sourceHash(source)
        let audio = try APIConfiguration.apiBaseURL().appending(path: "v1/media/translations/\(id.uuidString.lowercased())/\(hash)-th-v1.m4a")
        let api = DubbedAudioCacheClient(
            client: HTTP("{\"status\":\"ready\",\"sourceHash\":\"\(hash)\",\"audioURL\":\"\(audio.absoluteString)\"}"),
            authorization: Authorization())
        #expect(try await api.lookup(videoID: id, sourceURL: source, language: .thai) == audio)
    }
}
