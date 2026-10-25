import AVFoundation
import Foundation
import Testing
@testable import Marauders

/// What `DubbingViewModel.prepare` decides: saved audio, a language declared by the uploader,
/// or a language the viewer's own iPhone has to detect first.
@MainActor
struct DubbingPlanTests {
    private final class Cache: DubbedAudioCaching, @unchecked Sendable {
        private let url: URL?
        private(set) var lookedUp: [String] = []
        init(_ url: URL? = nil) { self.url = url }
        func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL? {
            lookedUp.append(language.code)
            return url
        }
        func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws {}
    }

    private final class Detector: ClipLanguageDetecting {
        var result: SpeechLanguageDetection?
        private(set) var candidates: [[String]] = []
        init(_ result: SpeechLanguageDetection? = nil) { self.result = result }
        func detect(sample: URL, among candidates: [SpeechLanguageCandidate]) async -> SpeechLanguageDetection? {
            self.candidates.append(candidates.map(\.code))
            return result
        }
    }

    private final class Loader: ClipFileLoading {
        let file: URL
        private(set) var loads = 0
        init(_ file: URL) { self.file = file }
        func load(_ url: URL, into folder: URL, check: () throws -> Void) async throws -> URL {
            loads += 1
            return file
        }
    }

    private final class Counter {
        var count = 0
    }

    /// A short non-silent clip, so the first speech segment exists for detection.
    private func speechFile() throws -> URL {
        var pcm = Data()
        for index in 0..<16_000 {
            var sample = Int16(8_000 * sin(Double(index) * 2 * .pi * 440 / 16_000)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try SpeechAudioPreparation.wave(pcm).write(to: url)
        return url
    }

    private func silentFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try SpeechAudioPreparation.wave(Data(repeating: 0, count: 32_000)).write(to: url)
        return url
    }

    private func memo() -> DetectedLanguageMemo { DetectedLanguageMemo(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!) }

    private func clip(_ declared: SpokenLanguageAssessment? = nil) -> FeedVideo {
        FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!,
                  audioAssessment: ClipAudioAssessment(content: .speech, signal: .detected, spokenLanguage: declared))
    }

    private struct Rig {
        let model: DubbingViewModel
        let cache: Cache
        let detector: Detector
        let loader: Loader
        let memo: DetectedLanguageMemo
        let permissionAsked: Counter
    }

    private func rig(cache: Cache = Cache(), detected: SpeechLanguageDetection? = nil, file: URL, permission: Bool = true, memo: DetectedLanguageMemo? = nil) -> Rig {
        let detector = Detector(detected)
        let loader = Loader(file)
        let asked = Counter()
        let memo = memo ?? self.memo()
        let model = DubbingViewModel(cache: cache, detector: detector, loader: loader, memo: memo) {
            asked.count += 1
            return permission
        }
        return Rig(model: model, cache: cache, detector: detector, loader: loader, memo: memo, permissionAsked: asked)
    }

    @Test func savedAudioWinsAndNeedsNoDetectionOrPermission() async throws {
        let audio = try speechFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let rig = rig(cache: Cache(audio), file: audio)
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .cached(audio))
        #expect(rig.cache.lookedUp == ["th"])
        #expect(rig.detector.candidates.isEmpty)
        #expect(rig.loader.loads == 0)
        #expect(rig.permissionAsked.count == 0)
        #expect(rig.model.message == String(localized: "AI audio in \(ListeningLanguage.thai.sentenceName()) · using saved audio"))
    }

    @Test func aDeclaredLanguageSkipsDetectionAndTheDownload() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        #expect(await rig.model.prepare(clip: clip(.chosen("es")), target: .thai) == .translate(source: .spanish))
        #expect(rig.cache.lookedUp == ["th"])
        #expect(rig.detector.candidates.isEmpty)
        #expect(rig.loader.loads == 0)
        #expect(rig.permissionAsked.count == 0)
    }

    @Test func aClipAlreadyInTheListeningLanguageKeepsTheOriginal() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        #expect(await rig.model.prepare(clip: clip(.chosen("en")), target: .english) == .unavailable)
        #expect(rig.model.message == DubbingError.alreadyInListeningLanguage(language: ListeningLanguage.english.sentenceName()).errorDescription)
        #expect(rig.cache.lookedUp.isEmpty)
    }

    @Test func aDeclaredLanguageWeCannotDubFromKeepsTheOriginal() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        #expect(await rig.model.prepare(clip: clip(.chosen("fr")), target: .thai) == .unavailable)
        let french = ListeningLanguage.interfaceLocale.localizedString(forLanguageCode: "fr") ?? "fr"
        #expect(rig.model.message == DubbingError.sourceUnsupported(language: french).errorDescription)
        #expect(rig.detector.candidates.isEmpty)
    }

    @Test func anUndeclaredLanguageIsDetectedOnThisPhoneAndRemembered() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file)
        let video = clip()
        let plan = await rig.model.prepare(clip: video, target: .thai)
        #expect(plan == .translate(source: .spanish))
        #expect(rig.permissionAsked.count == 1)
        #expect(rig.loader.loads == 1)
        // Both dubbing sources and the viewer's own language are tried.
        #expect(Set(rig.detector.candidates.first ?? []) == ["en", "es", "th"])
        #expect(rig.memo.code(for: video.id) == "es")
        rig.model.useOriginal()
    }

    @Test func aRememberedLanguageIsNotDetectedAgain() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let memo = memo()
        let video = clip()
        memo.remember("es", for: video.id)
        let rig = rig(file: file, memo: memo)
        #expect(await rig.model.prepare(clip: video, target: .thai) == .translate(source: .spanish))
        #expect(rig.detector.candidates.isEmpty)
        #expect(rig.loader.loads == 0)
    }

    @Test func detectingTheViewersOwnLanguageKeepsTheOriginal() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "en", confidence: 0.9), file: file)
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .english) == .unavailable)
        #expect(rig.model.message == DubbingError.alreadyInListeningLanguage(language: ListeningLanguage.english.sentenceName()).errorDescription)
        #expect(rig.memo.code(for: video.id) == "en")
    }

    @Test func aDetectedLanguageWeCannotDubFromKeepsTheOriginal() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "th", confidence: 0.9), file: file)
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .english) == .unavailable)
        let thai = ListeningLanguage.interfaceLocale.localizedString(forLanguageCode: "th") ?? "th"
        #expect(rig.model.message == DubbingError.sourceUnsupported(language: thai).errorDescription)
        #expect(rig.memo.code(for: video.id) == "th")
    }

    @Test func anUndetectableClipSaysSoAndKeepsTheOriginal() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: nil, file: file)
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .thai) == .unavailable)
        #expect(rig.model.message == DubbingError.languageUndetected.errorDescription)
        #expect(rig.memo.code(for: video.id) == nil)
        #expect(!rig.model.isProcessing)
    }

    @Test func deniedSpeechPermissionStopsBeforeDownloading() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file, permission: false)
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .unavailable)
        #expect(rig.model.message == DubbingError.permission.errorDescription)
        #expect(rig.loader.loads == 0)
        #expect(rig.detector.candidates.isEmpty)
    }

    @Test func aClipWithoutSpeechCannotBeDetected() async throws {
        let file = try silentFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file)
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .unavailable)
        #expect(rig.model.message == DubbingError.speechUnclear.errorDescription)
        #expect(rig.detector.candidates.isEmpty)
    }

    @Test func choosingTheOriginalDuringDetectionDiscardsTheResult() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file)
        let video = clip()
        let pending = Task { await rig.model.prepare(clip: video, target: .thai) }
        // Switching back to the original audio cancels whatever is in flight.
        rig.model.useOriginal()
        let plan = await pending.value
        #expect(plan == .unavailable || plan == .translate(source: .spanish))
        rig.model.useOriginal()
        #expect(rig.model.message == nil)
        #expect(!rig.model.isProcessing)
    }

    @Test func firstSpeechSegmentIsEnoughForDetection() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let segments = try await SpeechAudioPreparation.chunks(from: file, directory: folder, maximumSegments: 1)
        #expect(segments.count == 1)
    }
}
