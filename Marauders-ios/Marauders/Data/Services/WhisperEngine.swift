//
//  WhisperEngine.swift
//  Marauders
//

import Foundation
@preconcurrency import WhisperKit

/// Listens to a clip with the on-device Whisper model: it names the language of a window and writes
/// down what the clip says.
///
/// It is an actor so the model loads and runs on its own executor instead of the main actor, and one
/// shared instance serves every player so the model is never held in memory twice. The model is kept
/// for a short while after the last use and then unloaded, because it holds on to a lot of memory.
/// It reads only from the installed folders (the install verified the tokenizer loads from disk), so
/// listening needs no network.
actor WhisperEngine: AcousticLanguageIdentifying, AcousticTranscribing {
    static let shared = WhisperEngine()

    private enum Unavailable: Error { case modelNotInstalled }

    private let store: LanguageDetectionModelStore
    private let idle: Duration
    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private var active = 0
    private var unloadTask: Task<Void, Never>?
    private var unloadToken: UUID?

    init(store: LanguageDetectionModelStore = .shared, idle: Duration = .seconds(20)) {
        self.store = store
        self.idle = idle
    }

    func identify(window: URL) async -> AcousticLanguageGuess? {
        do {
            return try await withModel { kit in
                let result = try await kit.detectLanguage(audioPath: window.path)
                // WhisperKit reports the winner's log probability.
                guard let logProbability = result.langProbs[result.language] else { return nil }
                return AcousticLanguageGuess(code: result.language, probability: exp(Double(logProbability)))
            }
        } catch {
            if !(error is CancellationError), !(error is Unavailable) {
                await AppLog.warning("dubbing.language", "Acoustic language check failed")
            }
            return nil
        }
    }

    func transcribe(file: URL, languageCode: String) async throws -> AcousticTranscript? {
        do {
            return try await withModel { kit in
                let results = try await kit.transcribe(
                    audioPath: file.path,
                    audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                    decodeOptions: Self.decodingOptions(language: languageCode)
                )
                let segments = results.flatMap(\.segments).map {
                    AcousticSegment(text: $0.text, averageLogProbability: Double($0.avgLogprob), compressionRatio: Double($0.compressionRatio))
                }
                return AcousticTranscriptPolicy.transcript(from: segments)
            }
        } catch Unavailable.modelNotInstalled {
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await AppLog.warning("dubbing.transcribe", "Whisper transcription failed")
            throw error
        }
    }

    /// Transcribing in the given language, with WhisperKit's defaults for retrying a pass that looks doubtful.
    /// The whole file goes in at once and WhisperKit decides where to cut (it splits audio longer than 30
    /// seconds at a quiet moment, and cuts hard only when it finds none). Fixed 20-second windows do not work:
    /// the second one of the Dutch test clip starts in the middle of a word, and a greedy pass on it ended at
    /// once with nothing in 10 of 10 runs, while the retries (which sample at random) got text only in some
    /// runs. Handing over the whole file gave the same text in every run, for the 41-second clip and for the
    /// same clip repeated to 120 and 200 seconds (about 3 percent more words than the repeats ideally hold).
    private static func decodingOptions(language: String) -> DecodingOptions {
        DecodingOptions(task: .transcribe, language: language, temperature: 0, skipSpecialTokens: true)
    }

    /// Runs `body` with the model loaded, which stays loaded for a while afterwards. Throws
    /// `Unavailable.modelNotInstalled` when the model is not on this iPhone.
    private func withModel<Result>(_ body: (WhisperKit) async throws -> Result) async throws -> Result {
        active += 1
        unloadTask?.cancel()
        unloadTask = nil
        unloadToken = nil
        defer {
            active -= 1
            if active == 0 { scheduleUnload() }
        }
        guard let folders = await store.installedFolders() else { throw Unavailable.modelNotInstalled }
        return try await body(try await loadedKit(from: folders))
    }

    /// Loads the model once, however many callers ask for it at the same time.
    private func loadedKit(from folders: LanguageDetectionModelStore.Folders) async throws -> WhisperKit {
        if let kit { return kit }
        if let loading { return try await loading.value }
        let task = Task {
            try await WhisperKit(WhisperKitConfig(
                modelFolder: folders.model.path,
                tokenizerFolder: folders.tokenizerBase,
                computeOptions: LanguageDetectionModelStore.computeOptions,
                verbose: false,
                logLevel: .none,
                load: true,
                download: false
            ))
        }
        loading = task
        do {
            let created = try await task.value
            kit = created
            loading = nil
            return created
        } catch {
            loading = nil
            throw error
        }
    }

    private func scheduleUnload() {
        let token = UUID()
        unloadToken = token
        unloadTask = Task { [idle] in
            do { try await Task.sleep(for: idle) } catch { return }
            await self.unload(ifStill: token)
        }
    }

    /// Drops the model unless a newer use arrived while this one was waiting.
    private func unload(ifStill token: UUID) async {
        guard unloadToken == token, active == 0, let loaded = kit else { return }
        unloadToken = nil
        unloadTask = nil
        kit = nil
        await loaded.unloadModels()
    }
}
