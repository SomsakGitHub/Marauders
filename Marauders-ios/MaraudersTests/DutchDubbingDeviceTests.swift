import AVFoundation
import Foundation
import Speech
import SwiftUI
import Testing
@preconcurrency import Translation
import UIKit
@testable import Marauders

/// Dubs the real Dutch clip into English on a real iPhone through `DubbingViewModel.request`, the call the
/// player's translation task makes: transcribe with the Whisper model, translate, speak. It does not go
/// through `ClipPlayerView` or `prepare`, starts from a clip that was fetched beforehand, uploads nothing
/// (there is no cache context) and uses a translation session hosted in a window of its own. It needs the
/// production feed to hold the Dutch test clip, Apple's Dutch to English translation pair, and the language detection
/// model (downloaded when missing: about a minute the first time). It needs no speech permission.
/// The translation session uses the default strategy: the player asks for `.lowLatency`, whose models can need
/// their own one-time system download that a test cannot confirm (`prepareTranslation` then waits for a tap).
/// Dutch into Thai needs such a prompt too, so it is not covered. It only runs when asked:
/// `TEST_RUNNER_RUN_DEVICE_DUBBING_TEST=1 xcodebuild test -only-testing:MaraudersTests/DutchDubbingDeviceTests ...`
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_DEVICE_DUBBING_TEST"] != nil, "Set TEST_RUNNER_RUN_DEVICE_DUBBING_TEST=1"))
@MainActor
struct DutchDubbingDeviceTests {
    private let feedURL = URL(string: "https://marauders-api.js6ctz7gtj.workers.dev/v1/feed?limit=1")!

    /// The clip at the top of the production feed, which is expected to be the Dutch market dialogue. It has been
    /// deleted and uploaded again before, so its address is looked up instead of written down.
    private func clipURL() async throws -> URL {
        struct Feed: Decodable {
            struct Item: Decodable { let streamURL: URL }
            let items: [Item]
        }
        let (data, response) = try await URLSession.shared.data(from: feedURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        try #require(status == 200, "the production feed is not available (HTTP \(status))")
        return try #require(try JSONDecoder().decode(Feed.self, from: data).items.first?.streamURL, "the production feed has no clip")
    }

    /// Words and phrases from the turns of the test clip (a vendor and a customer at a market stall, about
    /// 17 short turns, about 89 words), spread over both windows. The Dictation engine this route replaced
    /// heard about 43 words and none of the second half's "betalen" or "paprika's ... drie" turns.
    private static let turnsOfTheClip = [
        "goeiemorgen", "geoogst", "kilo tomaten", "nog iets anders", "wortelen", "komkommers",
        "paprika", "aanbieding", "betalen", "heerlijk", "smakelijk", "dank u wel"
    ]

    private struct Host: View {
        let configuration: TranslationSession.Configuration
        let work: @MainActor (TranslationSession) async -> Void
        var body: some View {
            Text("Translation host")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .translationTask(configuration) { session in await work(session) }
        }
    }

    /// Runs `work` inside a real `translationTask`, because a `TranslationSession` only exists there. The
    /// host is a visible window of its own on top of the app, like the player the session normally lives in.
    private func insideTranslationTask(source: String, target: String, work: @escaping @MainActor (TranslationSession) async -> Void) async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("no window scene to host the translation task")
            return
        }
        let configuration = TranslationSession.Configuration(source: .init(identifier: source), target: .init(identifier: target))
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = Once()
            let host = UIHostingController(rootView: Host(configuration: configuration) { session in
                await work(session)
                if finished.first() { continuation.resume() }
            })
            window.rootViewController = host
            window.makeKeyAndVisible()
            Task {
                try? await Task.sleep(for: .seconds(240))
                if finished.first() { continuation.resume() }
            }
        }
        window.isHidden = true
    }

    /// The production clip, fetched into `folder`, failing clearly when it is gone.
    private func fetchClip(into folder: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: try await clipURL())
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        try #require(status == 200, "the production clip is not available (HTTP \(status))")
        let file = folder.appendingPathComponent("clip.mp4")
        try data.write(to: file)
        return file
    }

    /// The language detection model on this iPhone, installed first when it is missing.
    private func ensureWhisperModel() async throws {
        if await LanguageDetectionModelStore.shared.installedFolders() != nil { return }
        print("DUB_TEST installing the language detection model")
        try await LanguageDetectionModelStore.shared.install { _ in }
        try #require(await LanguageDetectionModelStore.shared.installedFolders() != nil)
    }

    private func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// What the Whisper route writes down for the clip, read from the engine the player uses.
    private func transcribeTheClip(_ clip: URL) async throws -> String {
        try #require(try await WhisperEngine.shared.transcribe(file: clip, languageCode: "nl")).text
    }

    /// The reason for switching to the Whisper model: the engine used before heard about half of this clip.
    /// The clip's turns are listed in `turnsOfTheClip`; a few word errors are normal for the base model, so this
    /// asks for most of them rather than all.
    @Test func whisperHearsMostTurnsOfTheClip() async throws {
        try await ensureWhisperModel()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("turns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await fetchClip(into: folder)
        let clock = ContinuousClock()
        let started = clock.now
        let text = try await transcribeTheClip(clip)
        let lowered = text.lowercased()
        let heard = Self.turnsOfTheClip.filter { lowered.contains($0) }
        print("DUB_TEST whisper heard \(wordCount(text)) words, \(heard.count)/\(Self.turnsOfTheClip.count) turn markers, took \(clock.now - started)")
        print("DUB_TEST whisper text: \(text)")
        print("DUB_TEST missing markers: \(Self.turnsOfTheClip.filter { !lowered.contains($0) })")
        #expect(wordCount(text) >= 80)
        #expect(heard.count >= 10)
        // Nothing the model writes for the music at the end of the clip is read out.
        #expect(!text.contains("♫"))
        #expect(!lowered.contains("gelderland"))
    }

    /// Leaving the player cancels the task that is waiting for the transcript; the model must stop with it
    /// instead of finishing a transcription nobody will read.
    @Test func cancellingTheTaskStopsTheTranscription() async throws {
        try await ensureWhisperModel()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await fetchClip(into: folder)
        // Warm: the model is loaded and the full run is timed.
        let clock = ContinuousClock()
        var started = clock.now
        _ = try await transcribeTheClip(clip)
        let full = clock.now - started
        started = clock.now
        let task = Task { try await WhisperEngine.shared.transcribe(file: clip, languageCode: "nl") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        let elapsed = clock.now - started
        print("DUB_TEST full run \(full), cancelled run \(elapsed), threw CancellationError=\(cancelled)")
        #expect(cancelled)
        // It stopped early rather than finishing a transcription nobody will read.
        #expect(elapsed < full)
    }

    @Test func dubsTheDutchClipIntoEnglish() async throws {
        try await ensureWhisperModel()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let availability = await LanguageAvailability().status(from: .init(identifier: "nl"), to: .init(identifier: "en"))
        print("DUB_TEST translation nl->en availability=\(availability)")
        #expect(availability == .installed)

        let clock = ContinuousClock()
        let outcome = Outcome()
        // Fetch the clip up front, so the test measures dubbing and not the clip download.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let localClip = try await fetchClip(into: folder)
        try await insideTranslationTask(source: "nl", target: "en") { session in
            // What the Whisper route hears, and what that becomes in English, for a human to judge.
            do {
                let dutch = try await transcribeTheClip(localClip)
                print("DUB_TEST dutch=\(dutch)")
                try await session.prepareTranslation()
                let english = try await session.translate(dutch).targetText
                print("DUB_TEST english=\(english)")
                outcome.dutch = dutch
                outcome.english = english
            } catch {
                print("DUB_TEST transcript/translation error \(error)")
            }

            // The real thing: the same call the player makes. Speech permission is refused on purpose,
            // because the Whisper route must not need it.
            let model = DubbingViewModel(requestSpeechPermission: { false })
            let started = clock.now
            let url = await model.request(sourceURL: localClip, session: session, source: .dutch, target: .english)
            outcome.seconds = clock.now - started
            outcome.message = model.message
            if let url {
                outcome.audioSeconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                outcome.produced = FileManager.default.fileExists(atPath: url.path)
            }
            model.useOriginal()
        }
        print("DUB_TEST request took \(outcome.seconds), produced=\(outcome.produced), audio=\(outcome.audioSeconds)s, message=\(outcome.message ?? "nil")")
        #expect(outcome.produced)
        // The voice now covers the whole conversation, not the half the dictation engine heard (13.8 s).
        #expect(outcome.audioSeconds > 20)
        #expect(outcome.dutch.lowercased().contains("tomaten"))
        #expect(outcome.english.lowercased().contains("tomato"))
        // The status line ends on the finished voice, not on an error.
        #expect(outcome.message == String(localized: "AI voice reads the translation on this iPhone · timing may differ from the original"))
    }
}

@MainActor
private final class Outcome {
    var dutch = ""
    var english = ""
    var seconds: Duration = .zero
    var audioSeconds = 0.0
    var produced = false
    var message: String?
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
