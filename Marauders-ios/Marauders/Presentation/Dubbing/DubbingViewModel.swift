import Foundation
import Observation
import AVFoundation
import Speech
@preconcurrency import Translation

@MainActor @Observable
final class DubbingViewModel {
    /// What to do once the viewer asked for AI audio in a language.
    enum Plan: Equatable {
        /// Saved AI audio exists; play it.
        case cached(URL)
        /// Translate on this iPhone from the clip's language.
        case translate(source: DubbingSourceLanguage)
        /// Nothing to play; `message` says why.
        case unavailable
    }

    private(set) var message: String?
    private(set) var isProcessing = false
    private let cache: any DubbedAudioCaching
    private let detector: any ClipLanguageDetecting
    private let loader: any ClipFileLoading
    private let memo: DetectedLanguageMemo
    private let requestSpeechPermission: () async -> Bool
    private var cacheContext: (videoID: UUID, sourceURL: URL, target: ListeningLanguage)?
    /// The clip's local file once downloaded for detection, kept so translating does not fetch it again.
    private var preparedClip: (sourceURL: URL, fileURL: URL)?
    private var generation = 0

    init(
        cache: (any DubbedAudioCaching)? = nil,
        detector: (any ClipLanguageDetecting)? = nil,
        loader: (any ClipFileLoading)? = nil,
        memo: DetectedLanguageMemo? = nil,
        requestSpeechPermission: (() async -> Bool)? = nil
    ) {
        self.cache = cache ?? DubbedAudioCacheClient()
        self.detector = detector ?? StagedClipLanguageDetector()
        self.loader = loader ?? ClipFileLoader()
        self.memo = memo ?? DetectedLanguageMemo.shared
        self.requestSpeechPermission = requestSpeechPermission ?? { await SpeechPermission.request() }
    }

    /// Decides how to give the viewer AI audio in `target`: saved audio if someone already made it,
    /// otherwise translation from the clip's language, which this iPhone detects itself when the
    /// uploader did not say. Runs before a TranslationSession exists, so a cache hit needs no
    /// speech permission or installed translation models.
    func prepare(clip: FeedVideo, target: ListeningLanguage) async -> Plan {
        useOriginal()
        generation += 1
        let current = generation
        cacheContext = (clip.id, clip.streamURL, target)
        isProcessing = true
        defer { if current == generation { isProcessing = false } }
        do {
            let declared = clip.declaredSourceCode ?? memo.code(for: clip.id)
            if let declared { try Self.requireDubbable(from: declared, into: target) }
            message = String(localized: "Checking for saved AI audio…")
            if let audio = await savedAudio(for: clip, target: target, current: current) { return .cached(audio) }
            try check(current)
            if let declared, let source = DubbingSourceLanguage(code: declared) {
                message = nil
                return .translate(source: source)
            }
            return .translate(source: try await detectSource(of: clip, target: target, current: current))
        } catch {
            guard current == generation else { return .unavailable }
            message = error is CancellationError ? nil : ((error as? DubbingError) ?? .failed).errorDescription
            cleanFiles()
            return .unavailable
        }
    }

    private func savedAudio(for clip: FeedVideo, target: ListeningLanguage, current: Int) async -> URL? {
        do {
            guard let audio = try await cache.lookup(videoID: clip.id, sourceURL: clip.streamURL, language: target) else { return nil }
            try check(current)
            guard try await AVURLAsset(url: audio).load(.isPlayable) else { return nil }
            try check(current)
            message = String(localized: "AI audio in \(target.sentenceName()) · using saved audio")
            return audio
        } catch { return nil }
    }

    /// Recognizes the first stretch of speech as each language this iPhone can dub from, and as the
    /// viewer's own language, to learn what the clip speaks. The answer is remembered for the clip.
    private func detectSource(of clip: FeedVideo, target: ListeningLanguage, current: Int) async throws -> DubbingSourceLanguage {
        message = String(localized: "Detecting the language spoken in this clip…")
        guard await requestSpeechPermission() else { throw DubbingError.permission }
        try check(current)
        let folder = try makeWorkFolder()
        let file = try await loader.load(clip.streamURL, into: folder) { try check(current) }
        preparedClip = (clip.streamURL, file)
        try check(current)
        guard let sample = try await SpeechAudioPreparation.chunks(from: file, directory: folder, maximumSegments: 1).first else {
            throw DubbingError.speechUnclear
        }
        try check(current)
        var candidates = DubbingSourceLanguage.allCases.map(\.candidate)
        if let own = SpeechLanguageCandidate.recognizable(target.code), !candidates.contains(where: { $0.code == own.code }) {
            candidates.append(own)
        }
        guard let detection = await detector.detect(sample: sample, among: candidates) else { throw DubbingError.languageUndetected }
        try check(current)
        memo.remember(detection.code, for: clip.id)
        try Self.requireDubbable(from: detection.code, into: target)
        guard let source = DubbingSourceLanguage(code: detection.code) else {
            throw DubbingError.sourceUnsupported(language: Self.languageName(detection.code))
        }
        return source
    }

    /// Throws for the two outcomes that mean "keep the original": the clip already speaks the
    /// viewer's language, or its language is one we cannot dub from yet.
    private static func requireDubbable(from code: String, into target: ListeningLanguage) throws {
        if code == target.code { throw DubbingError.alreadyInListeningLanguage(language: target.sentenceName()) }
        guard DubbingSourceLanguage(code: code) != nil else {
            throw DubbingError.sourceUnsupported(language: languageName(code))
        }
    }

    private static func languageName(_ code: String) -> String {
        ListeningLanguage.interfaceLocale.localizedString(forLanguageCode: code) ?? code
    }

    private func makeWorkFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dubbing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
        return folder
    }

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionContinuation: CheckedContinuation<String, Error>?
    private var synthesizer: AVSpeechSynthesizer?
    private var writer: NarrationFileWriter?
    private var directory: URL?
    private var recognitionID: UUID?
    private var recognitionTimeout: Task<Void, Never>?

    /// Called only following an explicit choice to listen in `target`. The system may request
    /// language-model downloads, but clip speech/text stays on device.
    func request(sourceURL: URL, session: TranslationSession, source language: DubbingSourceLanguage, target: ListeningLanguage) async -> URL? {
        let context = cacheContext?.sourceURL == sourceURL && cacheContext?.target == target ? cacheContext : nil
        let reusable = preparedClip?.sourceURL == sourceURL ? preparedClip : nil
        reset(keepingClip: reusable != nil)
        cacheContext = context
        generation += 1
        let current = generation
        isProcessing = true
        defer { if generation == current { isProcessing = false } }
        do {
            let sourceName = language.displayName()
            let targetName = target.sentenceName()
            let availability = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: .init(identifier: language.translationCode), to: .init(identifier: target.code))
            guard availability != .unsupported else { throw DubbingError.pairUnsupported(source: sourceName, target: targetName) }
            message = availability == .installed
                ? String(localized: "Preparing \(sourceName) and \(targetName) on this iPhone…")
                : String(localized: "First-time translation download · you can download ahead in Settings › Language models")
            try await session.prepareTranslation()
            try check(current)
            // The legacy recognizer handles English; other languages use the SpeechAnalyzer model.
            var speech: SFSpeechRecognizer?
            if language == .english {
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocale)), recognizer.supportsOnDeviceRecognition else { throw DubbingError.unavailable }
                speech = recognizer
            }
            guard let voice = SpeechVoiceCatalog.voice(for: target) else { throw DubbingError.voiceUnavailable(language: targetName) }
            let permission = await requestSpeechPermission()
            try check(current)
            guard permission else { throw DubbingError.permission }
            message = String(localized: "Preparing the clip's audio on this iPhone…")
            let folder: URL
            let videoURL: URL
            if let reusable, let kept = directory {
                // Already downloaded while detecting the language.
                folder = kept
                videoURL = reusable.fileURL
            } else {
                folder = try makeWorkFolder()
                videoURL = try await loader.load(sourceURL, into: folder) { try check(current) }
            }
            try check(current)
            let asset = AVURLAsset(url: videoURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw DubbingError.failed }
            let segments = try await SpeechAudioPreparation.chunks(from: videoURL, directory: folder)
            var words: [String] = []
            for (index, segment) in segments.enumerated() {
                try check(current)
                message = String(localized: "Transcribing \(sourceName) speech on this iPhone… \(index + 1)/\(segments.count)")
                let text: String
                if let speech {
                    text = try await transcribe(segment, recognizer: speech)
                } else {
                    text = try await transcribeWithAnalyzer(segment, language: language)
                }
                words.append(text)
            }
            let text = words.joined(separator: " ")
            try check(current)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DubbingError.speechUnclear }
            message = String(localized: "Translating into \(targetName) on this iPhone…")
            let translated = try await session.translate(text).targetText
            try check(current)
            message = String(localized: "Creating the AI voice on this iPhone…")
            let output = folder.appendingPathComponent("dubbed.caf")
            let synth = AVSpeechSynthesizer()
            synthesizer = synth
            let utterance = AVSpeechUtterance(string: translated)
            utterance.voice = voice
            let result: URL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let outputWriter = NarrationFileWriter(url: output, continuation: continuation)
                    writer = outputWriter
                    synth.write(utterance) { @Sendable buffer in outputWriter.append(buffer) }
                }
            } onCancel: { Task { @MainActor [weak self] in if self?.generation == current { self?.cancelWork() } } }
            try check(current)
            message = String(localized: "AI voice reads the translation on this iPhone · timing may differ from the original")
            if let context {
                do {
                    let data = try await DubbedAudioCacheEncoding.encode(source: result, destination: folder.appendingPathComponent("dubbed.m4a"))
                    try check(current)
                    message = String(localized: "AI audio in \(targetName) · saving for others to reuse")
                    let cache = self.cache
                    // Retain bounded compressed data, not temporary file URLs. Closing
                    // playback may delete files while the idempotent upload completes.
                    Task { [weak self] in
                        do {
                            try await cache.store(videoID: context.videoID, sourceURL: context.sourceURL, language: context.target, audio: data)
                            guard let self, self.generation == current else { return }
                            self.message = String(localized: "AI audio in \(targetName) · saved for reuse")
                        } catch {
                            #if DEBUG
                            print("DUBBED_AUDIO_CACHE_UPLOAD_FAILED \(error)")
                            #endif
                            guard let self, self.generation == current else { return }
                            self.message = String(localized: "AI audio in \(targetName) · couldn't save on the server, but you can keep listening")
                        }
                    }
                } catch is CancellationError { return nil }
                catch {
                    guard current == generation else { return nil }
                    message = String(localized: "AI audio in \(targetName) · couldn't save on the server, but you can keep listening")
                }
            }
            return result
        } catch {
            #if DEBUG
            let failure = error as NSError
            print("LOCAL_TRANSLATION_FAILURE domain=\(failure.domain) code=\(failure.code) stage=\(message ?? "unknown")")
            #endif
            guard current == generation else { return nil }
            if !(error is CancellationError) { message = (error as? DubbingError)?.errorDescription ?? DubbingError.failed.errorDescription }
            cancelWork()
            cleanFiles()
            return nil
        }
    }
    private func check(_ current: Int) throws {
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
    }
    private func transcribeWithAnalyzer(_ url: URL, language: DubbingSourceLanguage) async throws -> String {
        do {
            // The viewer explicitly asked for AI audio, so a first-time model download is acceptable here.
            guard let transcript = try await SpeechAnalyzerTranscriber.transcribe(
                file: url, localeIdentifier: language.speechLocale, downloadModelIfNeeded: true, timeout: .seconds(60)
            ) else { throw DubbingError.unavailable }
            return transcript.text
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DubbingError {
            throw error
        } catch {
            throw DubbingError.speechUnclear
        }
    }
    private func transcribe(_ url: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        let operationID = UUID()
        recognitionID = operationID
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recognitionContinuation = continuation
                recognitionTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.recognitionID == operationID else { return }
                    let pending = self.recognitionContinuation
                    self.recognitionContinuation = nil
                    pending?.resume(throwing: DubbingError.speechUnclear)
                    self.cancelWork()
                }
                recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                    let finalText = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                    let failed = error != nil
                    let speechFailure = error as NSError?
                    let noSpeech = speechFailure?.domain == "kAFAssistantErrorDomain" && speechFailure?.code == 1110
                    #if DEBUG
                    if let failure = error as NSError? { print("LOCAL_SPEECH_FAILURE domain=\(failure.domain) code=\(failure.code) description=\(failure.localizedDescription)") }
                    #endif
                    Task { @MainActor in
                        guard let self, self.recognitionID == operationID, let pending = self.recognitionContinuation else { return }
                        if let finalText { self.recognitionTimeout?.cancel(); self.recognitionContinuation = nil; pending.resume(returning: finalText) }
                        else if noSpeech { self.recognitionTimeout?.cancel(); self.recognitionContinuation = nil; pending.resume(returning: "") }
                        else if failed { self.recognitionTimeout?.cancel(); self.recognitionContinuation = nil; pending.resume(throwing: DubbingError.speechUnclear) }
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.recognitionID == operationID { self?.cancelWork() } } }
    }
    private func cancelWork() {
        recognitionID = nil
        recognitionTimeout?.cancel(); recognitionTimeout = nil
        recognitionTask?.cancel(); recognitionTask = nil
        let pending = recognitionContinuation; recognitionContinuation = nil
        pending?.resume(throwing: CancellationError())
        recognizer = nil
        writer?.cancel(); writer = nil
        synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil
    }
    private func cleanFiles() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        preparedClip = nil
    }
    func useOriginal() {
        reset(keepingClip: false)
    }
    /// Stops whatever is running. A clip already downloaded for detection is kept when the next
    /// step is translating that same clip.
    private func reset(keepingClip: Bool) {
        generation += 1
        cancelWork()
        if !keepingClip { cleanFiles() }
        cacheContext = nil
        isProcessing = false; message = nil
    }
    func unavailableForTesting() {
        useOriginal()
        message = DubbingError.unavailable.errorDescription
    }
    func playbackFailed() {
        useOriginal()
        message = String(localized: "Couldn't play the AI audio. Using the original audio.")
    }
}
