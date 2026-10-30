import Foundation
import Testing
@testable import Marauders

@MainActor
struct DubbedAudioReportTests {
    private struct Authorization: APIAuthorization {
        func bearerAuthorizationHeader() -> String? { "Bearer fixture-session" }
    }
    private actor HTTP: HTTPClient {
        private(set) var requests: [URLRequest] = []
        let body: Data
        let status: Int
        init(_ body: String, status: Int = 200) { self.body = Data(body.utf8); self.status = status }
        func data(_ request: URLRequest) async throws -> HTTPClientResponse { requests.append(request); return .init(data: body, statusCode: status) }
        func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse { throw HTTPClientError.invalidResponse }
    }
    private final class Cache: DubbedAudioCaching, @unchecked Sendable {
        var outcome: Result<DubbedAudioReportOutcome, Error>
        var reporterID: String? = "user-a"
        private(set) var reported: [String] = []
        init(_ outcome: Result<DubbedAudioReportOutcome, Error>) { self.outcome = outcome }
        func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL? { nil }
        func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws {}
        func report(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> DubbedAudioReportOutcome {
            reported.append(language.code)
            return try outcome.get()
        }
    }
    private let source = URL(string: "https://example.com/video.mp4")!
    private func memory() -> DubbedAudioReportMemory {
        DubbedAudioReportMemory(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
    }

    @Test func requestShape() async throws {
        let id = UUID()
        let http = HTTP("{\"status\":\"reported\",\"reports\":1}")
        let api = DubbedAudioCacheClient(client: http, authorization: Authorization())
        #expect(try await api.report(videoID: id, sourceURL: source, language: .thai) == .reported)
        let request = try #require(await http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("/v1/videos/\(id.uuidString.lowercased())/dubbed-audio/report") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.count == 1)
        #expect(query.first { $0.name == "lang" }?.value == "th")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-session")
        #expect(request.value(forHTTPHeaderField: "X-Source-SHA256") == DubbedAudioCacheClient.sourceHash(source))
        #expect(request.timeoutInterval == 15)
        #expect(request.httpBody == nil)
    }

    @Test func decodesEachStatus() async throws {
        for (body, expected) in [
            ("{\"status\":\"reported\",\"reports\":1}", DubbedAudioReportOutcome.reported),
            ("{\"status\":\"removed\"}", .removed),
            ("{\"status\":\"missing\"}", .missing)
        ] {
            let api = DubbedAudioCacheClient(client: HTTP(body), authorization: Authorization())
            #expect(try await api.report(videoID: UUID(), sourceURL: source, language: .spanish) == expected)
        }
    }

    @Test func rejectsBadReplies() async {
        for status in [401, 404, 409, 429, 500] {
            let api = DubbedAudioCacheClient(client: HTTP("{\"error\":\"x\"}", status: status), authorization: Authorization())
            do { _ = try await api.report(videoID: UUID(), sourceURL: source, language: .thai); Issue.record("Accepted \(status)") }
            catch let DubbedAudioCacheError.http(code) { #expect(code == status) }
            catch { Issue.record("Wrong error \(error)") }
        }
        for body in ["{\"status\":\"banana\"}", "not json", "{}"] {
            let api = DubbedAudioCacheClient(client: HTTP(body), authorization: Authorization())
            do { _ = try await api.report(videoID: UUID(), sourceURL: source, language: .thai); Issue.record("Accepted \(body)") }
            catch { }
        }
    }

    @Test func guestCannotReport() async {
        let http = HTTP("{\"status\":\"removed\"}")
        let api = DubbedAudioCacheClient(client: http, authorization: NoAPIAuthorization())
        do { _ = try await api.report(videoID: UUID(), sourceURL: source, language: .thai); Issue.record("Guest report sent") }
        catch { #expect(await http.requests.isEmpty) }
    }

    @Test func defaultImplementationFails() async {
        final class Plain: DubbedAudioCaching, @unchecked Sendable {
            func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL? { nil }
            func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws {}
        }
        do { _ = try await Plain().report(videoID: UUID(), sourceURL: source, language: .thai); Issue.record("Default succeeded") }
        catch { #expect(error is DubbingError) }
    }

    @Test func buttonIsOfferedOnlyWhileAIAudioPlays() {
        let model = DubbingViewModel(cache: Cache(.success(.reported)), reports: memory())
        let clip = FeedVideo(streamURL: source)
        #expect(model.canReport(clip: clip, target: .thai, aiTrackPlaying: true))
        #expect(!model.canReport(clip: clip, target: .thai, aiTrackPlaying: false))
        #expect(!model.canReport(clip: clip, target: nil, aiTrackPlaying: true))
    }

    @Test func outcomesMapToNoticesAndStopAIAudio() async {
        let clip = FeedVideo(streamURL: source)
        for (outcome, expected) in [(DubbedAudioReportOutcome.reported, DubbingViewModel.ReportResult.reported),
                                    (.removed, .removed), (.missing, .removed)] {
            let cache = Cache(.success(outcome))
            let model = DubbingViewModel(cache: cache, reports: memory())
            #expect(await model.report(clip: clip, target: .thai) == expected)
            #expect(expected.stopsAIAudio)
            #expect(cache.reported == ["th"])
            // Only a recorded report hides the button; after removal or "missing" it may be needed again.
            #expect(model.canReport(clip: clip, target: .thai, aiTrackPlaying: true) == (expected != .reported))
        }
        #expect(DubbingViewModel.ReportResult.reported.notice == String(localized: "Thanks. This audio will be removed once another viewer reports it too."))
        #expect(DubbingViewModel.ReportResult.removed.notice == String(localized: "The audio was removed."))
    }

    @Test func failureKeepsPlayingAndStaysReportable() async {
        let clip = FeedVideo(streamURL: source)
        let model = DubbingViewModel(cache: Cache(.failure(DubbedAudioCacheError.http(500))), reports: memory())
        let result = await model.report(clip: clip, target: .thai)
        #expect(result == .failed)
        #expect(!result.stopsAIAudio)
        #expect(model.canReport(clip: clip, target: .thai, aiTrackPlaying: true))
    }

    @Test func guestIsNotOfferedTheButton() async {
        let cache = Cache(.success(.reported))
        cache.reporterID = nil
        let model = DubbingViewModel(cache: cache, reports: memory())
        let clip = FeedVideo(streamURL: source)
        #expect(!model.canReport(clip: clip, target: .thai, aiTrackPlaying: true))
        #expect(await model.report(clip: clip, target: .thai) == .failed)
        #expect(cache.reported.isEmpty)
    }

    @Test func reportedAudioIsHiddenOnlyForTheSameAccount() async {
        let cache = Cache(.success(.reported))
        let model = DubbingViewModel(cache: cache, reports: memory())
        let clip = FeedVideo(streamURL: source)
        _ = await model.report(clip: clip, target: .thai)
        #expect(!model.canReport(clip: clip, target: .thai, aiTrackPlaying: true))
        cache.reporterID = "user-b"
        #expect(model.canReport(clip: clip, target: .thai, aiTrackPlaying: true))
    }

    @Test func clientReadsTheUserFromTheToken() {
        struct Token: APIAuthorization { let value: String?; func bearerAuthorizationHeader() -> String? { value } }
        let payload = Data("{\"sub\":\"abc-123\"}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(DubbedAudioCacheClient(client: HTTP("{}"), authorization: Token(value: "Bearer h.\(payload).s")).reporterID == "abc-123")
        #expect(DubbedAudioCacheClient(client: HTTP("{}"), authorization: Token(value: "Bearer opaque")).reporterID == "signed-in")
        #expect(DubbedAudioCacheClient(client: HTTP("{}"), authorization: NoAPIAuthorization()).reporterID == nil)
    }

    @Test func memoryIsPerClipLanguageAndRevision() {
        let suite = "tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = DubbedAudioReportMemory(defaults: defaults)
        let id = UUID()
        first.remember(user: "u", videoID: id, language: .thai, sourceURL: source)
        #expect(first.hasReported(user: "u", videoID: id, language: .thai, sourceURL: source))
        #expect(!first.hasReported(user: "u", videoID: id, language: .spanish, sourceURL: source))
        #expect(!first.hasReported(user: "u", videoID: UUID(), language: .thai, sourceURL: source))
        #expect(!first.hasReported(user: "u", videoID: id, language: .thai, sourceURL: URL(string: "https://example.com/other.mp4")!))
        // Survives a relaunch.
        #expect(DubbedAudioReportMemory(defaults: defaults).hasReported(user: "u", videoID: id, language: .thai, sourceURL: source))
    }

    @Test func memoryDropsOldestPastItsLimit() {
        let small = DubbedAudioReportMemory(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!, limit: 2)
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { small.remember(user: "u", videoID: id, language: .thai, sourceURL: source) }
        #expect(!small.hasReported(user: "u", videoID: ids[0], language: .thai, sourceURL: source))
        #expect(small.hasReported(user: "u", videoID: ids[2], language: .thai, sourceURL: source))
    }
}
