import AVFoundation
import Foundation
import Testing
@testable import Marauders

/// End to end on a real iPhone: the store downloads the pinned files, the identifier loads them from disk
/// and names the language of the real Dutch clip. These tests download about 150 MB into the app's real
/// Application Support folder and need the clip to still be on the server, so they run only when asked.
///
/// Install, detect and the reload timing (needs Hugging Face):
///   TEST_RUNNER_RUN_DEVICE_LANGUAGE_TESTS=1 xcodebuild test -scheme Marauders -destination 'platform=iOS,id=<device>' \
///     -only-testing:MaraudersTests/LanguageDetectionDeviceTests
///
/// Detection with every Hugging Face request pointed at a dead address (run it on its own, after the above):
///   TEST_RUNNER_RUN_DEVICE_LANGUAGE_TESTS=1 TEST_RUNNER_RUN_DEVICE_OFFLINE_TEST=1 TEST_RUNNER_HF_ENDPOINT=http://127.0.0.1:9 \
///     xcodebuild test ... -only-testing:'MaraudersTests/LanguageDetectionDeviceTests/detectsWithoutAnyNetworkAccess()'
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_DEVICE_LANGUAGE_TESTS"] != nil, "Set TEST_RUNNER_RUN_DEVICE_LANGUAGE_TESTS=1"))
@MainActor
struct LanguageDetectionDeviceTests {
    private let clipURL = URL(string: "https://marauders-api.js6ctz7gtj.workers.dev/v1/media/videos/ae774227-23aa-4a61-a173-1fa1fe23a45b.mp4")!

    private func windowsOfTheDutchClip(in folder: URL) async throws -> [URL] {
        let file = try await ClipFileLoader().load(clipURL, into: folder) {}
        return try await SpeechAudioPreparation.chunks(from: file, directory: folder, maximumSegments: 2)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func expectKeptOutOfBackups(_ store: LanguageDetectionModelStore) async throws {
        guard let folders = await store.installedFolders() else {
            Issue.record("the model should be installed")
            return
        }
        var url = folders.tokenizerBase
        while url.lastPathComponent != "LanguageDetection", url.pathComponents.count > 2 { url.deleteLastPathComponent() }
        #expect(url.lastPathComponent == "LanguageDetection")
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        print("DEVICE_TEST \(url.lastPathComponent) excludedFromBackup=\(String(describing: values.isExcludedFromBackup))")
        #expect(values.isExcludedFromBackup == true)
    }

    private func ensureInstalled() async throws {
        let store = LanguageDetectionModelStore.shared
        if await !store.isInstalled() { try await store.install { _ in } }
    }

    @Test func aFreshInstallThenNamesTheLanguageOfTheDutchClip() async throws {
        let clock = ContinuousClock()
        let store = LanguageDetectionModelStore.shared
        await store.remove()
        #expect(await store.status() == .notInstalled)

        let started = clock.now
        let log = ProgressLog()
        try await store.install { fraction in log.report(fraction) }
        print("DEVICE_TEST install took \(clock.now - started)")
        #expect(await store.isInstalled())
        #expect(await store.status() == .installed)
        try await expectKeptOutOfBackups(store)

        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let windows = try await windowsOfTheDutchClip(in: folder)
        #expect(windows.count == 2)

        let identifier = WhisperEngine()
        let first = clock.now
        let guess = await AcousticClipLanguageDetector(identifier: identifier).detect(windows: windows)
        print("DEVICE_TEST first detection (includes loading the model) took \(clock.now - first): \(String(describing: guess))")
        #expect(guess?.code == "nl")
        #expect((guess?.probability ?? 0) >= AcousticLanguagePolicy.rememberAbove)

        let again = clock.now
        let second = await AcousticClipLanguageDetector(identifier: identifier).detect(windows: windows)
        print("DEVICE_TEST second detection took \(clock.now - again): \(String(describing: second))")
        #expect(second?.code == "nl")
    }

    /// Loading the model in a fresh process is slow (about 9 s); loading it again after the idle unload is not.
    @Test func reloadingAfterTheIdleUnloadIsQuick() async throws {
        try await ensureInstalled()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let windows = try await windowsOfTheDutchClip(in: folder)
        let detector = AcousticClipLanguageDetector(identifier: WhisperEngine(idle: .seconds(1)))
        let clock = ContinuousClock()
        var durations: [Duration] = []
        for round in 1...3 {
            let started = clock.now
            let guess = await detector.detect(windows: windows)
            durations.append(clock.now - started)
            print("DEVICE_TEST round \(round) took \(durations[round - 1]): \(guess?.code ?? "nil")")
            #expect(guess?.code == "nl")
            try await Task.sleep(for: .seconds(4))   // longer than the 1 s idle, so the model is dropped in between
        }
        // After the idle unload the model comes back in about a second, nowhere near the slow first load of a fresh launch.
        #expect(durations[1] < .seconds(5))
        #expect(durations[2] < .seconds(5))
    }

    /// The assertion that nothing needs Hugging Face once the files are on the phone. Fails if the
    /// process was not started with the dead address, so it cannot pass by accident.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_DEVICE_OFFLINE_TEST"] != nil, "Set TEST_RUNNER_RUN_DEVICE_OFFLINE_TEST=1"))
    func detectsWithoutAnyNetworkAccess() async throws {
        #expect(ProcessInfo.processInfo.environment["HF_ENDPOINT"] == "http://127.0.0.1:9", "start with TEST_RUNNER_HF_ENDPOINT=http://127.0.0.1:9")
        guard await LanguageDetectionModelStore.shared.isInstalled() else {
            Issue.record("run the install test first; this one cannot download")
            return
        }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let windows = try await windowsOfTheDutchClip(in: folder)
        let clock = ContinuousClock()
        let started = clock.now
        let guess = await AcousticClipLanguageDetector(identifier: WhisperEngine()).detect(windows: windows)
        print("DEVICE_TEST offline detection (cold launch) took \(clock.now - started): \(String(describing: guess))")
        #expect(guess?.code == "nl")
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTenth = -1
    func report(_ fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        let tenth = Int(fraction * 10)
        guard tenth != lastTenth else { return }
        lastTenth = tenth
        print("DEVICE_TEST install \(Int(fraction * 100))%")
    }
}
