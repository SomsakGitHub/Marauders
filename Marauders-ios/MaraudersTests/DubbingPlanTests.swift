import AVFoundation
import Foundation
import Testing
@testable import Marauders

/// What `DubbingViewModel.prepare` decides: saved audio, a language the clip declares,
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

    nonisolated private final class FakeModels: LanguageDetectionModelManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var present: Bool
        private var installCount = 0
        let failure: Error?
        /// True when another screen already started the download.
        let downloading: Bool
        /// Runs after each progress report, so a test can read the status line in the middle of the install.
        nonisolated(unsafe) var afterProgress: (@Sendable () async -> Void)?
        init(installed: Bool = false, failure: Error? = nil, downloading: Bool = false) {
            present = installed
            self.failure = failure
            self.downloading = downloading
        }
        var installs: Int { lock.withLock { installCount } }
        func isInstalled() async -> Bool { lock.withLock { present } }
        func status() async -> LanguageModelStatus {
            if lock.withLock({ present }) { return .installed }
            return downloading ? .downloading(progress: 0.3) : .notInstalled
        }
        func install(progress: @escaping @Sendable (Double) -> Void) async throws {
            lock.withLock { installCount += 1 }
            progress(0.45)
            await afterProgress?()
            if let failure { throw failure }
            progress(0.95)
            await afterProgress?()
            lock.withLock { present = true }
            progress(1)
        }
        func remove() async { lock.withLock { present = false } }
    }

    /// Answers one scripted guess per window it is asked about.
    nonisolated private final class FakeAcoustic: AcousticLanguageIdentifying, @unchecked Sendable {
        private let lock = NSLock()
        private var guesses: [AcousticLanguageGuess?]
        private var asked = 0
        init(_ guesses: [AcousticLanguageGuess?] = []) { self.guesses = guesses }
        var windowsAsked: Int { lock.withLock { asked } }
        func identify(window: URL) async -> AcousticLanguageGuess? {
            lock.withLock {
                asked += 1
                return guesses.isEmpty ? nil : guesses.removeFirst()
            }
        }
    }

    enum TranscriberOutcome { case transcript(AcousticTranscript), missingModel, failure }

    nonisolated static func makeTranscriber(_ outcome: TranscriberOutcome) -> any AcousticTranscribing {
        switch outcome {
        case .transcript(let transcript): FakeTranscriber(.transcript(transcript))
        case .missingModel: FakeTranscriber(.missingModel)
        case .failure: FakeTranscriber(.failure)
        }
    }

    nonisolated static func requests(of transcriber: any AcousticTranscribing) -> [(file: URL, language: String)] {
        (transcriber as? FakeTranscriber)?.requests ?? []
    }

    /// Answers the transcript it is given, or fails, and counts the files it was asked about.
    nonisolated private final class FakeTranscriber: AcousticTranscribing, @unchecked Sendable {
        enum Outcome { case transcript(AcousticTranscript), missingModel, failure }
        private let lock = NSLock()
        private let outcome: Outcome
        private var asked: [(file: URL, language: String)] = []
        init(_ outcome: Outcome) { self.outcome = outcome }
        var requests: [(file: URL, language: String)] { lock.withLock { asked } }
        func transcribe(file: URL, languageCode: String) async throws -> AcousticTranscript? {
            lock.withLock { asked.append((file, languageCode)) }
            switch outcome {
            case .transcript(let transcript): return transcript
            case .missingModel: return nil
            case .failure: throw URLError(.unknown)
            }
        }
    }

    private func consent(declined: Bool) -> LanguageDetectionConsent {
        let consent = LanguageDetectionConsent()
        if declined { consent.decline() }
        return consent
    }

    /// Long enough for two detection windows: 20 seconds and a clearly long second one of 10.
    private func longSpeechFile() throws -> URL {
        var pcm = Data()
        for index in 0..<(16_000 * 30) {
            var sample = Int16(8_000 * sin(Double(index) * 2 * .pi * 440 / 16_000)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try SpeechAudioPreparation.wave(pcm).write(to: url)
        return url
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
        let models: FakeModels
        let acoustic: FakeAcoustic
        let consent: LanguageDetectionConsent
    }

    /// By default the viewer has said "Not now" to the detection model, so detection is the limited,
    /// recognizer-based one these tests were written for.
    private func rig(
        cache: Cache = Cache(), detected: SpeechLanguageDetection? = nil, file: URL, permission: Bool = true,
        memo: DetectedLanguageMemo? = nil, models: FakeModels = FakeModels(), acoustic: FakeAcoustic = FakeAcoustic(),
        declined: Bool = true
    ) -> Rig {
        let detector = Detector(detected)
        let loader = Loader(file)
        let asked = Counter()
        let memo = memo ?? self.memo()
        let consent = consent(declined: declined)
        let model = DubbingViewModel(cache: cache, detector: detector, loader: loader, memo: memo,
                                     models: models, acoustic: acoustic, consent: consent) {
            asked.count += 1
            return permission
        }
        return Rig(model: model, cache: cache, detector: detector, loader: loader, memo: memo, permissionAsked: asked,
                   models: models, acoustic: acoustic, consent: consent)
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
        // Without the detection model the message points to it.
        #expect(rig.model.message == DubbingError.languageUndetectedWithoutModel.errorDescription)
        #expect(rig.memo.code(for: video.id) == nil)
        #expect(!rig.model.isProcessing)
    }

    // MARK: Language detection model

    @Test func anUnknownClipAsksBeforeDownloadingTheModel() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, declined: false)
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .needsDetectionModel)
        #expect(rig.model.message == nil)
        #expect(rig.models.installs == 0)
        #expect(rig.loader.loads == 0)
        #expect(rig.permissionAsked.count == 0)
        #expect(!rig.model.isProcessing)
    }

    @Test func aKnownLanguageNeverAsksForTheModel() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, declined: false)
        #expect(await rig.model.prepare(clip: clip(.chosen("es")), target: .thai) == .translate(source: .spanish))
        #expect(rig.models.installs == 0)
    }

    @Test func agreeingDownloadsTheModelThenListensAndNamesTheLanguage() async throws {
        let file = try longSpeechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let acoustic = FakeAcoustic([.init(code: "ru", probability: 0.97), .init(code: "ru", probability: 0.99)])
        let rig = rig(file: file, acoustic: acoustic, declined: false)
        let video = clip()
        // Russian is found, but dubbing from Russian is not supported yet.
        #expect(await rig.model.prepare(clip: video, target: .thai, downloadingDetectionModel: true) == .unavailable)
        let russian = ListeningLanguage.interfaceLocale.localizedString(forLanguageCode: "ru") ?? "ru"
        #expect(rig.model.message == DubbingError.sourceUnsupported(language: russian).errorDescription)
        #expect(rig.models.installs == 1)
        #expect(acoustic.windowsAsked == 2)
        #expect(rig.memo.code(for: video.id) == "ru")
        // Naming a language needs no speech permission, and the old recognizers were not used.
        #expect(rig.permissionAsked.count == 0)
        #expect(rig.detector.candidates.isEmpty)
    }

    @Test func agreeingToTheDownloadShowsItsProgressThenThePreparation() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let models = FakeModels()
        let rig = rig(file: file, models: models, acoustic: FakeAcoustic([.init(code: "ru", probability: 0.97)]), declined: false)
        let seen = Seen()
        let model = rig.model
        // The status line is written by a task hopped onto the main actor; let it run before looking.
        models.afterProgress = {
            await MainActor.run {}
            await MainActor.run { seen.messages.append(model.message ?? "nil") }
        }
        _ = await rig.model.prepare(clip: clip(), target: .thai, downloadingDetectionModel: true)
        #expect(seen.messages == [
            String(localized: "Downloading the language detection model… \(50)%"),
            String(localized: "Preparing the language detection model on this iPhone…")
        ])
    }

    @Test func aDownloadAlreadyRunningIsJoinedNotAskedAboutAgain() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let models = FakeModels(downloading: true)
        let rig = rig(file: file, models: models, acoustic: FakeAcoustic([.init(code: "ru", probability: 0.99)]), declined: false)
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .unavailable)
        #expect(models.installs == 1)
        let russian = ListeningLanguage.interfaceLocale.localizedString(forLanguageCode: "ru") ?? "ru"
        #expect(rig.model.message == DubbingError.sourceUnsupported(language: russian).errorDescription)
    }

    @Test func aDoubtfulAnswerIsActedOnButNotRemembered() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, models: FakeModels(installed: true), acoustic: FakeAcoustic([.init(code: "ru", probability: 0.85)]))
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .thai) == .unavailable)
        let russian = ListeningLanguage.interfaceLocale.localizedString(forLanguageCode: "ru") ?? "ru"
        #expect(rig.model.message == DubbingError.sourceUnsupported(language: russian).errorDescription)
        // Not remembered, so the audio button stays and a better answer can come later.
        #expect(rig.memo.code(for: video.id) == nil)
    }

    @Test func aShortTrailingWindowIsNotAskedAbout() async throws {
        // 21 seconds: a 20-second window and a 1-second tail that says too little to overrule it.
        var pcm = Data()
        for index in 0..<(16_000 * 21) {
            var sample = Int16(8_000 * sin(Double(index) * 2 * .pi * 440 / 16_000)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try SpeechAudioPreparation.wave(pcm).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let acoustic = FakeAcoustic([.init(code: "ru", probability: 0.97), .init(code: "de", probability: 0.9)])
        let rig = rig(file: file, models: FakeModels(installed: true), acoustic: acoustic)
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .unavailable)
        #expect(acoustic.windowsAsked == 1)
        #expect(rig.permissionAsked.count == 0)
    }

    @Test func aNamedLanguageWeCanDubFromGoesStraightToTranslation() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, models: FakeModels(installed: true), acoustic: FakeAcoustic([.init(code: "es", probability: 0.97)]))
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .thai) == .translate(source: .spanish))
        #expect(rig.models.installs == 0)
        #expect(rig.memo.code(for: video.id) == "es")
        #expect(rig.permissionAsked.count == 0)
        rig.model.useOriginal()
    }

    @Test func aClipInTheViewersLanguageKeepsTheOriginalWhenTheModelSaysSo() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, models: FakeModels(installed: true), acoustic: FakeAcoustic([.init(code: "th", probability: 0.97)]))
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .unavailable)
        #expect(rig.model.message == DubbingError.alreadyInListeningLanguage(language: ListeningLanguage.thai.sentenceName()).errorDescription)
    }

    @Test func windowsThatDisagreeFallBackToTheRecognizers() async throws {
        let file = try longSpeechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let acoustic = FakeAcoustic([.init(code: "nl", probability: 0.95), .init(code: "de", probability: 0.9)])
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file, models: FakeModels(installed: true), acoustic: acoustic)
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .thai) == .translate(source: .spanish))
        #expect(acoustic.windowsAsked == 2)
        #expect(rig.permissionAsked.count == 1)
        #expect(Set(rig.detector.candidates.first ?? []) == ["en", "es", "th"])
        #expect(rig.memo.code(for: video.id) == "es")
        rig.model.useOriginal()
    }

    @Test func anUnsureModelAndNoRecognizerAnswerMeansUndetected() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: nil, file: file, models: FakeModels(installed: true), acoustic: FakeAcoustic([.init(code: "nl", probability: 0.5)]))
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .thai) == .unavailable)
        #expect(rig.model.message == DubbingError.languageUndetected.errorDescription)
        #expect(rig.memo.code(for: video.id) == nil)
    }

    @Test func anUnsureModelAndDeniedPermissionMeansUndetectedNotAPermissionError() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, permission: false, models: FakeModels(installed: true), acoustic: FakeAcoustic([.init(code: "nl", probability: 0.5)]))
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .unavailable)
        #expect(rig.model.message == DubbingError.languageUndetected.errorDescription)
    }

    @Test func aFailedDownloadStillLetsTheRecognizersHandleEnglishAndSpanish() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file,
                      models: FakeModels(failure: URLError(.notConnectedToInternet)), declined: false)
        #expect(await rig.model.prepare(clip: clip(), target: .thai, downloadingDetectionModel: true) == .translate(source: .spanish))
        #expect(rig.models.installs == 1)
        #expect(rig.permissionAsked.count == 1)
        rig.model.useOriginal()
    }

    @Test func aFailedDownloadIsReportedWhenTheRecognizersFindNothing() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, models: FakeModels(failure: URLError(.notConnectedToInternet)), declined: false)
        #expect(await rig.model.prepare(clip: clip(), target: .thai, downloadingDetectionModel: true) == .unavailable)
        #expect(rig.model.message == DubbingError.detectionModelDownloadFailed.errorDescription)
    }

    @Test func aFailedDownloadIsNotHiddenBehindTheTroubleItLedTo() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // Speech permission was refused earlier; the viewer still needs to hear that the download failed.
        let rig = rig(file: file, permission: false, models: FakeModels(failure: URLError(.notConnectedToInternet)), declined: false)
        #expect(await rig.model.prepare(clip: clip(), target: .thai, downloadingDetectionModel: true) == .unavailable)
        #expect(rig.model.message == DubbingError.detectionModelDownloadFailed.errorDescription)
    }

    @Test func downloadFailuresAreToldApart() async throws {
        let cases: [(Error, DubbingError)] = [
            (LanguageDetectionModelError.unusable, .detectionModelUnusable),
            (LanguageDetectionModelError.incompleteDownload, .detectionModelDownloadFailed),
            (CocoaError(.fileWriteOutOfSpace), .detectionModelNoSpace),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .detectionModelNoSpace),
            (URLError(.timedOut), .detectionModelDownloadFailed)
        ]
        for (failure, expected) in cases {
            let file = try speechFile()
            defer { try? FileManager.default.removeItem(at: file) }
            let rig = rig(file: file, models: FakeModels(failure: failure), declined: false)
            _ = await rig.model.prepare(clip: clip(), target: .thai, downloadingDetectionModel: true)
            #expect(rig.model.message == expected.errorDescription, "\(failure)")
        }
    }

    @Test func decliningKeepsTheLimitedDetectionAndDoesNotAskAgain() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file)
        #expect(await rig.model.prepare(clip: clip(), target: .thai) == .translate(source: .spanish))
        #expect(rig.models.installs == 0)
        #expect(rig.permissionAsked.count == 1)
        rig.model.useOriginal()
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

    // MARK: Dutch

    @Test func aClipNamedDutchByTheModelIsDubbedFromDutch() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, models: FakeModels(installed: true), acoustic: FakeAcoustic([.init(code: "nl", probability: 0.99)]))
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .thai) == .translate(source: .dutch))
        #expect(rig.memo.code(for: video.id) == "nl")
        // Naming the language needs no speech permission; it is asked for when the clip is transcribed.
        #expect(rig.permissionAsked.count == 0)
        rig.model.useOriginal()
    }

    @Test func aRememberedDutchClipGoesStraightToTranslation() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let memo = memo()
        let video = clip()
        memo.remember("nl", for: video.id)
        let rig = rig(file: file, memo: memo, models: FakeModels(installed: true))
        #expect(await rig.model.prepare(clip: video, target: .english) == .translate(source: .dutch))
        #expect(rig.loader.loads == 0)
    }

    @Test func aDeclaredDutchClipForADutchViewerKeepsTheOriginal() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        let dutchViewer = try #require(ListeningLanguage(identifier: "nl"))
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: dutchViewer) == .unavailable)
        #expect(rig.model.message == DubbingError.alreadyInListeningLanguage(language: dutchViewer.sentenceName()).errorDescription)
    }

    // MARK: The Whisper model for Dutch

    @Test func dubbingFromDutchAsksBeforeDownloadingTheWhisperModel() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai) == .needsSpeechModel(.dutch))
        #expect(rig.model.message == nil)
        #expect(!rig.model.isProcessing)
        #expect(rig.models.installs == 0)
    }

    @Test func agreeingDownloadsTheModelThenMovesOnToTranslation() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai, downloadingSpeechModel: true) == .translate(source: .dutch))
        #expect(rig.models.installs == 1)
        #expect(await rig.models.isInstalled())
        rig.model.useOriginal()
    }

    @Test func theAgreementForTheDetectionQuestionDoesNotCoverTheSpeechModel() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai, downloadingDetectionModel: true) == .needsSpeechModel(.dutch))
        #expect(rig.models.installs == 0)
    }

    @Test func aDownloadAlreadyRunningIsJoinedForDutchWithoutAsking() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let models = FakeModels(downloading: true)
        let rig = rig(file: file, models: models)
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai) == .translate(source: .dutch))
        #expect(models.installs == 1)
        rig.model.useOriginal()
    }

    @Test func theModelOfADetectedDutchClipIsAlreadyThereSoNothingIsAskedAgain() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, models: FakeModels(installed: true), acoustic: FakeAcoustic([.init(code: "nl", probability: 0.99)]))
        let video = clip()
        #expect(await rig.model.prepare(clip: video, target: .thai) == .translate(source: .dutch))
        #expect(rig.models.installs == 0)
        rig.model.useOriginal()
    }

    @Test func theDownloadForDubbingNamesTheSpeechModelAndThenThePreparation() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let models = FakeModels()
        let rig = rig(file: file, models: models)
        let seen = Seen()
        let model = rig.model
        models.afterProgress = {
            await MainActor.run {}
            await MainActor.run { seen.messages.append(model.message ?? "nil") }
        }
        _ = await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai, downloadingSpeechModel: true)
        let dutch = DubbingSourceLanguage.dutch.displayName()
        #expect(seen.messages == [
            String(localized: "Downloading the \(dutch) speech model… \(50)%"),
            String(localized: "Preparing the language detection model on this iPhone…")
        ])
        rig.model.useOriginal()
    }

    @Test func aFailedSpeechModelDownloadNamesTheSpeechModelAndKeepsTheOriginal() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file, models: FakeModels(failure: URLError(.notConnectedToInternet)))
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai, downloadingSpeechModel: true) == .unavailable)
        #expect(rig.model.message == DubbingError.speechModelDownloadFailed(language: DubbingSourceLanguage.dutch.displayName()).errorDescription)
        #expect(!rig.model.isProcessing)
    }

    @Test func aFullPhoneOrAModelThatWillNotLoadKeepsItsOwnMessageForDutchToo() async throws {
        let cases: [(Error, DubbingError)] = [
            (CocoaError(.fileWriteOutOfSpace), .detectionModelNoSpace),
            (LanguageDetectionModelError.unusable, .detectionModelUnusable)
        ]
        for (failure, expected) in cases {
            let file = try speechFile()
            defer { try? FileManager.default.removeItem(at: file) }
            let rig = rig(file: file, models: FakeModels(failure: failure))
            _ = await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai, downloadingSpeechModel: true)
            #expect(rig.model.message == expected.errorDescription, "\(failure)")
        }
    }

    @Test func savedAudioForADutchClipNeedsNoModelAndNoQuestion() async throws {
        let audio = try speechFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let rig = rig(cache: Cache(audio), file: audio)
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai) == .cached(audio))
        #expect(rig.models.installs == 0)
    }

    @Test func aRememberedDutchClipAsksForTheModelToo() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let memo = memo()
        let video = clip()
        memo.remember("nl", for: video.id)
        let rig = rig(file: file, memo: memo)
        #expect(await rig.model.prepare(clip: video, target: .thai) == .needsSpeechModel(.dutch))
        #expect(rig.loader.loads == 0)
    }

    @Test func sayingNotNowToTheDetectionQuestionDoesNotAnswerTheSpeechModelQuestion() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // The detection question was declined earlier in this session (the rig's default).
        let rig = rig(file: file, declined: true)
        #expect(rig.consent.declined)
        #expect(await rig.model.prepare(clip: clip(.chosen("nl")), target: .thai) == .needsSpeechModel(.dutch))
    }

    @Test func englishAndSpanishNeverAskAboutASpeechModel() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        #expect(await rig.model.prepare(clip: clip(.chosen("es")), target: .thai) == .translate(source: .spanish))
        #expect(await rig.model.prepare(clip: clip(.chosen("en")), target: .thai) == .translate(source: .english))
        #expect(rig.models.installs == 0)
        rig.model.useOriginal()
    }

    @Test func decliningTheSpeechModelKeepsTheOriginalAndSaysWhy() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(file: file)
        rig.model.declineSpeechModel(for: .dutch)
        #expect(rig.model.message == DubbingError.speechModelDeclined(language: DubbingSourceLanguage.dutch.displayName()).errorDescription)
        #expect(!rig.model.isProcessing)
    }

    @Test func withoutTheModelOnlyEnglishSpanishAndTheViewersLanguageAreTried() async throws {
        let file = try speechFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let rig = rig(detected: .init(code: "es", confidence: 0.9), file: file)
        _ = await rig.model.prepare(clip: clip(), target: .thai)
        // Dutch is not among them: the quick recognizers cannot tell it, and trying would only cost time.
        #expect(Set(rig.detector.candidates.first ?? []) == ["en", "es", "th"])
        rig.model.useOriginal()
    }
}

/// What `DubbingViewModel.transcribeClip` does with what the Whisper model writes.
@MainActor
struct DutchTranscriptionTests {
    private func transcript(_ text: String, confidence: Double = 0.7) -> AcousticTranscript {
        AcousticTranscript(text: text, confidence: confidence)
    }

    private func run(_ outcome: DubbingPlanTests.TranscriberOutcome) async throws -> (text: String?, error: DubbingError?, asked: [(file: URL, language: String)]) {
        let transcriber = DubbingPlanTests.makeTranscriber(outcome)
        let model = DubbingViewModel(transcriber: transcriber)
        let clip = URL(fileURLWithPath: "/tmp/clip.mp4")
        do {
            let text = try await model.transcribeClip(at: clip, in: URL(fileURLWithPath: "/tmp"), language: .dutch, speech: nil, current: model.generation)
            return (text, nil, DubbingPlanTests.requests(of: transcriber))
        } catch let error as DubbingError {
            return (nil, error, DubbingPlanTests.requests(of: transcriber))
        }
    }

    @Test func theWholeClipGoesToTheModelInOneCallInTheClipsLanguage() async throws {
        let result = try await run(.transcript(transcript("Goeiemorgen, kan ik u helpen? Dan wil ik graag een kilo tomaten.")))
        #expect(result.text == "Goeiemorgen, kan ik u helpen? Dan wil ik graag een kilo tomaten.")
        #expect(result.asked.count == 1)
        #expect(result.asked.first?.file.lastPathComponent == "clip.mp4")
        #expect(result.asked.first?.language == "nl")
    }

    @Test func nothingHeardIsUnclearSpeech() async throws {
        #expect(try await run(.transcript(transcript("", confidence: 0))).error?.errorDescription == DubbingError.speechUnclear.errorDescription)
    }

    @Test func textThatDoesNotReadAsDutchIsRejectedBeforeItIsTranslatedAndShared() async throws {
        let english = "Good morning, can I help you? I would like a kilo of tomatoes and two cucumbers please."
        #expect(try await run(.transcript(transcript(english))).error?.errorDescription == DubbingError.speechUnclear.errorDescription)
    }

    @Test func textHeardWithTooLittleConfidenceIsRejected() async throws {
        let dutch = "Goeiemorgen, kan ik u helpen? Dan wil ik graag een kilo tomaten."
        #expect(try await run(.transcript(transcript(dutch, confidence: 0.3))).error?.errorDescription == DubbingError.speechUnclear.errorDescription)
    }

    @Test func aModelThatIsGoneMeansThisIPhoneIsNotReady() async throws {
        #expect(try await run(.missingModel).error?.errorDescription == DubbingError.unavailable.errorDescription)
    }

    @Test func aModelThatFailsIsNotBlamedOnTheClip() async throws {
        let error = try await run(.failure).error
        #expect(error?.errorDescription == DubbingError.failed.errorDescription)
        #expect(error?.errorDescription != DubbingError.speechUnclear.errorDescription)
    }
}

@MainActor
struct LanguageDetectionConsentTests {
    @Test func startsUndecidedAndRemembersNotNowForTheSession() {
        let consent = LanguageDetectionConsent()
        #expect(!consent.declined)
        consent.decline()
        #expect(consent.declined)
        // A new instance is a new session.
        #expect(!LanguageDetectionConsent().declined)
    }
}

@MainActor
private final class Seen {
    var messages: [String] = []
}
