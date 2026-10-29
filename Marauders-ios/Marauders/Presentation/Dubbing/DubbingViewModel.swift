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
        /// The clip's language is unknown and the model that tells it is not on this iPhone; ask the
        /// viewer to download it, then prepare again.
        case needsDetectionModel
        /// Dubbing from this language needs the Whisper model, which is not on this iPhone; ask the
        /// viewer to download it, then prepare again.
        case needsSpeechModel(DubbingSourceLanguage)
        /// Nothing to play; `message` says why.
        case unavailable
    }

    private(set) var message: String?
    private(set) var isProcessing = false
    /// The words of the AI voice, in the viewer's language, shown as subtitles while it plays.
    private(set) var subtitle: String?
    private let cache: any DubbedAudioCaching
    private let detector: any ClipLanguageDetecting
    private let loader: any ClipFileLoading
    private let memo: DetectedLanguageMemo
    private let models: any LanguageDetectionModelManaging
    private let acoustic: any AcousticLanguageIdentifying
    private let consent: LanguageDetectionConsent
    private let transcriber: any AcousticTranscribing
    private let requestSpeechPermission: () async -> Bool
    private var cacheContext: (videoID: UUID, sourceURL: URL, target: ListeningLanguage)?
    /// The clip's local file once downloaded for detection, kept so translating does not fetch it again.
    private var preparedClip: (sourceURL: URL, fileURL: URL)?
    /// Counts requests, so work that belongs to a request the viewer has left can tell and stop.
    private(set) var generation = 0

    init(
        cache: (any DubbedAudioCaching)? = nil,
        detector: (any ClipLanguageDetecting)? = nil,
        loader: (any ClipFileLoading)? = nil,
        memo: DetectedLanguageMemo? = nil,
        models: (any LanguageDetectionModelManaging)? = nil,
        acoustic: (any AcousticLanguageIdentifying)? = nil,
        transcriber: (any AcousticTranscribing)? = nil,
        consent: LanguageDetectionConsent? = nil,
        requestSpeechPermission: (() async -> Bool)? = nil
    ) {
        self.cache = cache ?? DubbedAudioCacheClient()
        self.detector = detector ?? StagedClipLanguageDetector()
        self.loader = loader ?? ClipFileLoader()
        self.memo = memo ?? DetectedLanguageMemo.shared
        self.models = models ?? LanguageDetectionModelStore.shared
        self.acoustic = acoustic ?? WhisperEngine.shared
        self.transcriber = transcriber ?? WhisperEngine.shared
        self.consent = consent ?? LanguageDetectionConsent.shared
        self.requestSpeechPermission = requestSpeechPermission ?? { await SpeechPermission.request() }
    }

    /// Decides how to give the viewer AI audio in `target`: saved audio if someone already made it,
    /// otherwise translation from the clip's language, which this iPhone detects itself unless the
    /// clip declares it. Runs before a TranslationSession exists, so a cache hit needs no
    /// speech permission or installed translation models.
    ///
    /// `downloadingDetectionModel` is true only for the call that follows the viewer agreeing to the
    /// language detection model download; a download that is already running is joined without asking.
    /// `downloadingSpeechModel` is the same for a clip whose language is known and is written down by the
    /// Whisper model (Dutch), which is the model the detection question is about too.
    func prepare(clip: FeedVideo, target: ListeningLanguage, downloadingDetectionModel agreed: Bool = false,
                 downloadingSpeechModel agreedToSpeechModel: Bool = false) async -> Plan {
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
                return try await planToTranslate(from: source, agreedToSpeechModel: agreedToSpeechModel, current: current)
            }
            var mayDownloadModel = agreed
            if await !models.isInstalled() {
                if case .downloading = await models.status() { mayDownloadModel = true }
                // Another request may have replaced this one while it was waiting for the answers above.
                try check(current)
                if !mayDownloadModel, !consent.declined {
                    message = nil
                    return .needsDetectionModel
                }
            }
            let detected = try await detectSource(of: clip, target: target, mayDownloadModel: mayDownloadModel, current: current)
            return try await planToTranslate(from: detected, agreedToSpeechModel: agreedToSpeechModel, current: current)
        } catch {
            guard current == generation else { return .unavailable }
            message = error is CancellationError ? nil : ((error as? DubbingError) ?? .failed).errorDescription
            cleanFiles()
            return .unavailable
        }
    }

    /// Translating from `source` is the plan. A language the Whisper model writes down needs that model on
    /// this iPhone: when it is missing the viewer is asked first, and a download they agreed to (or one that
    /// is already running) is finished here, before translating starts.
    private func planToTranslate(from source: DubbingSourceLanguage, agreedToSpeechModel: Bool, current: Int) async throws -> Plan {
        if source.speechEngine == .whisper, await !models.isInstalled() {
            var mayDownload = agreedToSpeechModel
            if case .downloading = await models.status() { mayDownload = true }
            try check(current)
            guard mayDownload else {
                message = nil
                return .needsSpeechModel(source)
            }
            do {
                try await downloadDetectionModel(current: current, for: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.downloadError(error, forSpeechIn: source)
            }
        }
        message = nil
        return .translate(source: source)
    }

    /// The viewer said "Not now" to a speech model download: keep the original audio and say why.
    func declineSpeechModel(for language: DubbingSourceLanguage) {
        useOriginal()
        message = DubbingError.speechModelDeclined(language: language.displayName()).errorDescription
    }

    private func savedAudio(for clip: FeedVideo, target: ListeningLanguage, current: Int) async -> URL? {
        do {
            guard let audio = try await cache.lookup(videoID: clip.id, sourceURL: clip.streamURL, language: target) else { return nil }
            try check(current)
            guard try await AVURLAsset(url: audio).load(.isPlayable) else { return nil }
            try check(current)
            message = String(localized: "AI audio in \(target.sentenceName()) · using saved audio")
            let text = await cache.lookupText(videoID: clip.id, sourceURL: clip.streamURL, language: target)
            if current == generation { subtitle = text }
            return audio
        } catch { return nil }
    }

    /// Works out what the clip speaks and remembers the answer. With the language detection model on
    /// this iPhone it listens to the first two stretches of speech and needs them to agree; without
    /// it, it recognizes the first stretch as each language this iPhone can dub from and as the
    /// viewer's own, which only covers a few languages.
    private func detectSource(of clip: FeedVideo, target: ListeningLanguage, mayDownloadModel: Bool, current: Int) async throws -> DubbingSourceLanguage {
        var hasModel = await models.isInstalled()
        var downloadFailure: DubbingError?
        if !hasModel, mayDownloadModel {
            do {
                try await downloadDetectionModel(current: current)
                hasModel = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // English and Spanish can still be recognized without the model, so carry on and
                // only report the failed download if that does not work out either.
                downloadFailure = Self.downloadError(error)
            }
        }
        do {
            return try await recognizeLanguage(of: clip, target: target, hasModel: hasModel, downloadFailure: downloadFailure, current: current)
        } catch let error as DubbingError {
            // A download that failed is the more useful thing to tell the viewer than the trouble it led to.
            guard let downloadFailure else { throw error }
            switch error {
            case .permission, .speechUnclear, .failed, .languageUndetected, .languageUndetectedWithoutModel: throw downloadFailure
            default: throw error
            }
        }
    }

    private func recognizeLanguage(of clip: FeedVideo, target: ListeningLanguage, hasModel: Bool, downloadFailure: DubbingError?, current: Int) async throws -> DubbingSourceLanguage {
        message = String(localized: "Detecting the language spoken in this clip…")
        // The listening model needs no speech permission; the recognizers do.
        if !hasModel { try await requireSpeechPermission(current: current) }
        let folder = try makeWorkFolder()
        let file = try await loader.load(clip.streamURL, into: folder) { try check(current) }
        preparedClip = (clip.streamURL, file)
        try check(current)
        let windows = try await SpeechAudioPreparation.detectionWindows(from: file, directory: folder, count: hasModel ? 2 : 1)
        guard let sample = windows.first else { throw DubbingError.speechUnclear }
        try check(current)

        if hasModel {
            // A short stretch left at the end of a clip says too little about the language to overrule the first.
            let heard = windows.enumerated().filter { $0.offset == 0 || SpeechAudioPreparation.seconds(ofWindow: $0.element) >= Self.shortestExtraWindow }.map(\.element)
            if let guess = await AcousticClipLanguageDetector(identifier: acoustic).detect(windows: heard) {
                try check(current)
                return try source(forDetected: guess.code, of: clip, target: target,
                                  remember: guess.probability >= AcousticLanguagePolicy.rememberAbove)
            }
            try check(current)
            // The model was unsure. The recognizers may still recognize English or Spanish.
            guard await requestSpeechPermission() else { throw DubbingError.languageUndetected }
            try check(current)
        }
        var candidates = DubbingSourceLanguage.recognizerCandidates
        if let own = SpeechLanguageCandidate.recognizable(target.code), !candidates.contains(where: { $0.code == own.code }) {
            candidates.append(own)
        }
        guard let detection = await detector.detect(sample: sample, among: candidates) else {
            throw downloadFailure ?? (hasModel ? DubbingError.languageUndetected : DubbingError.languageUndetectedWithoutModel)
        }
        try check(current)
        return try source(forDetected: detection.code, of: clip, target: target, remember: true)
    }

    /// A window after the first that is shorter than this is not asked about. The selector already leaves out
    /// such windows; this keeps the rule in force whatever supplies them.
    private static let shortestExtraWindow = 5.0

    private func requireSpeechPermission(current: Int) async throws {
        guard await requestSpeechPermission() else { throw DubbingError.permission }
        try check(current)
    }

    /// Turns a detected language into a dubbing source or says why that is not possible. The answer is
    /// remembered for the clip unless `remember` is false.
    private func source(forDetected code: String, of clip: FeedVideo, target: ListeningLanguage, remember: Bool) throws -> DubbingSourceLanguage {
        if remember { memo.remember(code, for: clip.id) }
        try Self.requireDubbable(from: code, into: target)
        guard let source = DubbingSourceLanguage(code: code) else {
            throw DubbingError.sourceUnsupported(language: Self.languageName(code))
        }
        return source
    }

    /// The viewer agreed to the download, so it starts now and shows its progress as the status line.
    /// `language` is set when the download is for dubbing from it rather than for finding a clip's language.
    private func downloadDetectionModel(current: Int, for language: DubbingSourceLanguage? = nil) async throws {
        message = language.map { String(localized: "Downloading the \($0.displayName()) speech model… this only happens once") }
            ?? String(localized: "Downloading the language detection model…")
        try await models.install { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                // The last part of the progress is the iPhone preparing the model, which is not a download.
                let share = LanguageDetectionModelStore.downloadShare
                let percent = Int(fraction / share * 100)
                if fraction >= share {
                    self.message = String(localized: "Preparing the language detection model on this iPhone…")
                } else if let language {
                    self.message = String(localized: "Downloading the \(language.displayName()) speech model… \(percent)%")
                } else {
                    self.message = String(localized: "Downloading the language detection model… \(percent)%")
                }
            }
        }
        try check(current)
    }

    /// What to tell the viewer about a download that failed: a full iPhone, a model that would not
    /// load, or (the common case) no connection to the server.
    private static func downloadError(_ error: Error, forSpeechIn language: DubbingSourceLanguage) -> DubbingError {
        let failure = downloadError(error)
        if case .detectionModelDownloadFailed = failure { return .speechModelDownloadFailed(language: language.displayName()) }
        return failure
    }

    private static func downloadError(_ error: Error) -> DubbingError {
        if let failure = error as? LanguageDetectionModelError {
            return failure == .unusable ? .detectionModelUnusable : .detectionModelDownloadFailed
        }
        let nsError = error as NSError
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return .detectionModelNoSpace
        }
        return .detectionModelDownloadFailed
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
            // The legacy recognizer handles English, the Whisper model Dutch; other languages use the SpeechAnalyzer model.
            var speech: SFSpeechRecognizer?
            if language == .english {
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocale)), recognizer.supportsOnDeviceRecognition else { throw DubbingError.unavailable }
                speech = recognizer
            }
            guard let voice = SpeechVoiceCatalog.voice(for: target) else { throw DubbingError.voiceUnavailable(language: targetName) }
            // Apple's recognizers need the viewer's permission; the Whisper model runs inside the app without it.
            if language.speechEngine != .whisper {
                let permission = await requestSpeechPermission()
                try check(current)
                guard permission else { throw DubbingError.permission }
            }
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
            let text = try await transcribeClip(at: videoURL, in: folder, language: language, speech: speech, current: current)
            message = String(localized: "Translating into \(targetName) on this iPhone…")
            let translated = try await session.translate(text).targetText
            try check(current)
            subtitle = translated.trimmingCharacters(in: .whitespacesAndNewlines)
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
                            try? await cache.storeText(videoID: context.videoID, sourceURL: context.sourceURL, language: context.target, text: translated)
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

    /// The words of the clip at `videoURL`, as the text that is translated next. Apple's engines read it in
    /// 20-second windows, one after the other; the Whisper model reads the whole file in one go, because a
    /// fixed window can start in the middle of a word and then come back empty. Throws `speechUnclear` when
    /// nothing usable was heard.
    func transcribeClip(at videoURL: URL, in folder: URL, language: DubbingSourceLanguage,
                        speech: SFSpeechRecognizer?, current: Int) async throws -> String {
        let sourceName = language.displayName()
        var pieces: [SpeechTranscript] = []
        if language.speechEngine == .whisper {
            message = String(localized: "Transcribing \(sourceName) speech on this iPhone…")
            pieces.append(try await transcribeWithModel(videoURL, language: language))
        } else {
            let segments = try await SpeechAudioPreparation.chunks(from: videoURL, directory: folder)
            for (index, segment) in segments.enumerated() {
                try check(current)
                message = String(localized: "Transcribing \(sourceName) speech on this iPhone… \(index + 1)/\(segments.count)")
                if let speech {
                    pieces.append(SpeechTranscript(text: try await transcribe(segment, recognizer: speech), confidence: 1))
                } else {
                    pieces.append(try await transcribeWithModel(segment, language: language))
                }
            }
        }
        let text = pieces.map(\.text).joined(separator: " ")
        try check(current)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DubbingError.speechUnclear }
        // The Whisper model writes whatever it hears in the language it is told, so make sure what came
        // out reads as that language and was heard with some confidence before it is translated, voiced
        // and shared with every later viewer of the clip.
        if language.speechEngine == .whisper {
            let characters = pieces.reduce(0) { $0 + $1.text.count }
            let confidence = characters == 0 ? 0 : pieces.reduce(0.0) { $0 + $1.confidence * Double($1.text.count) } / Double(characters)
            guard LanguageEvidence.transcriptIsPlausible(text: text, confidence: confidence, languageCode: language.translationCode) else {
                throw DubbingError.speechUnclear
            }
        }
        return text
    }
    /// Writes down the speech in `url`: a 20-second window for Apple's engines, the whole clip for Whisper.
    private func transcribeWithModel(_ url: URL, language: DubbingSourceLanguage) async throws -> SpeechTranscript {
        do {
            // The viewer explicitly asked for AI audio, so a first-time model download is acceptable here.
            // The Whisper model was already downloaded, after they were asked, when the plan was made.
            let transcript: SpeechTranscript?
            switch language.speechEngine {
            case .whisper:
                // Nil here means the model was removed after the plan was made. A model that fails is a
                // problem with this iPhone, not with the clip, so it does not say the speech was unclear.
                do {
                    transcript = try await transcriber.transcribe(file: url, languageCode: language.translationCode)
                        .map { SpeechTranscript(text: $0.text, confidence: $0.confidence) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw DubbingError.failed
                }
            case .recognizer, .speechTranscriber:
                transcript = try await SpeechAnalyzerTranscriber.transcribe(
                    file: url, localeIdentifier: language.speechLocale, downloadModelIfNeeded: true, timeout: .seconds(60)
                )
            }
            guard let transcript else { throw DubbingError.unavailable }
            return transcript
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DubbingError {
            throw error
        } catch SpeechModelInstallError.limitReached {
            throw DubbingError.speechModelLimit
        } catch SpeechModelInstallError.downloadFailed {
            throw DubbingError.speechModelDownloadFailed(language: language.displayName())
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
        isProcessing = false; message = nil; subtitle = nil
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
