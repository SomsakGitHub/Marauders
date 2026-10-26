//
//  LanguageModelsViewModelTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
private final class StubLanguageModelManager: LanguageModelManaging {
    var statuses: [LanguageModel.ID: LanguageModelStatus] = [:]
    /// Statuses handed out once, in order, before `statuses` applies again.
    var queuedStatuses: [LanguageModel.ID: [LanguageModelStatus]] = [:]
    var installError: Error?
    var installed: [String] = []
    var removed: [String] = []
    var detectionInstalls = 0
    var detectionRemovals = 0
    var detectionError: Error?

    func status(of model: LanguageModel) async -> LanguageModelStatus {
        if var queue = queuedStatuses[model.id], !queue.isEmpty {
            let next = queue.removeFirst()
            queuedStatuses[model.id] = queue
            return next
        }
        return statuses[model.id] ?? .notInstalled
    }

    func installSpeechModel(locale: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        progress(0.5)
        if let installError { throw installError }
        installed.append(locale)
        statuses["speech.\(locale)"] = .installed
    }

    func removeSpeechModel(locale: String) async -> Bool {
        removed.append(locale)
        statuses["speech.\(locale)"] = .notInstalled
        return true
    }

    func installDetectionModel(progress: @escaping @MainActor (Double) -> Void) async throws {
        progress(0.4)
        if let detectionError { throw detectionError }
        detectionInstalls += 1
        statuses[LanguageModel.detectionModels[0].id] = .installed
    }

    func removeDetectionModel() async {
        detectionRemovals += 1
        statuses[LanguageModel.detectionModels[0].id] = .notInstalled
    }
}

@MainActor
struct LanguageModelsViewModelTests {
    private let spanish = LanguageModel.speechModels.first { $0.id == "speech.es-ES" }!
    private let thaiPair = LanguageModel.translationModels(for: [.thai]).first { $0.id == "translation.en-th" }!

    /// A store that always listens in Thai, isolated from the device's saved settings.
    private func thaiListener() -> ListeningLanguageStore {
        let store = ListeningLanguageStore(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!, preferredLanguages: { [] })
        store.choose(.thai)
        return store
    }

    @Test func refreshLoadsStatusForEveryModel() async {
        let manager = StubLanguageModelManager()
        manager.statuses[spanish.id] = .installed
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        #expect(viewModel.status(of: spanish) == .checking)
        await viewModel.refresh()

        #expect(viewModel.status(of: spanish) == .installed)
        #expect(viewModel.status(of: thaiPair) == .notInstalled)
    }

    @Test func speechDownloadInstallsAndReportsInstalled() async {
        let manager = StubLanguageModelManager()
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(spanish)

        #expect(manager.installed == ["es-ES"])
        #expect(viewModel.status(of: spanish) == .installed)
    }

    /// Dutch is transcribed by the Whisper model, which has its own row; there is no Apple speech model to install for it.
    @Test func dutchHasNoAppleSpeechModelRowBecauseTheWhisperModelTranscribesIt() {
        #expect(!LanguageModel.speechModels.contains { $0.id == "speech.nl-NL" })
        #expect(!LanguageModel.speechModels.contains { if case .speech(let locale) = $0.kind { locale.hasPrefix("nl") } else { false } })
        #expect(LanguageModel.detectionModels.count == 1)
        #expect(DubbingSourceLanguage.dutch.speechEngine == .whisper)
    }

    @Test func speechDownloadFailureIsReportedAndRetryable() async {
        let manager = StubLanguageModelManager()
        manager.installError = LanguageModelError.unsupported
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(spanish)
        guard case .failed = viewModel.status(of: spanish) else {
            Issue.record("expected failed status"); return
        }

        manager.installError = nil
        await viewModel.download(spanish)
        #expect(viewModel.status(of: spanish) == .installed)
    }

    @Test func translationDownloadRequestsSessionThenFinishes() async {
        let manager = StubLanguageModelManager()
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(thaiPair)
        #expect(viewModel.translationConfiguration != nil)
        #expect(viewModel.status(of: thaiPair) == .downloading(progress: nil))

        manager.statuses[thaiPair.id] = .installed
        await viewModel.translationDownloadFinished(error: nil)
        #expect(viewModel.translationConfiguration == nil)
        #expect(viewModel.status(of: thaiPair) == .installed)
    }

    @Test func dismissedTranslationDownloadIsReportedAsFailureUnlessInstalled() async {
        let manager = StubLanguageModelManager()
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(thaiPair)
        await viewModel.translationDownloadFinished(error: LanguageModelError.unsupported)

        guard case .failed = viewModel.status(of: thaiPair) else {
            Issue.record("expected failed status"); return
        }
    }

    @Test func onlyInstalledSpeechModelsCanBeRemoved() async {
        let manager = StubLanguageModelManager()
        manager.statuses[spanish.id] = .installed
        manager.statuses[thaiPair.id] = .installed
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())
        await viewModel.refresh()

        #expect(viewModel.canRemove(spanish))
        #expect(!viewModel.canRemove(thaiPair))

        await viewModel.remove(thaiPair)
        #expect(manager.removed.isEmpty)
        await viewModel.remove(spanish)
        #expect(manager.removed == ["es-ES"])
        #expect(viewModel.status(of: spanish) == .notInstalled)
    }

    @Test func leavingBeforeTheSystemPromptDoesNotStrandTheRow() async {
        let manager = StubLanguageModelManager()
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(thaiPair)
        await viewModel.abandonTranslationDownload()

        #expect(viewModel.translationConfiguration == nil)
        #expect(viewModel.status(of: thaiPair) == .notInstalled)
    }

    @Test func refreshKeepsRowsThatAreStillDownloading() async {
        let manager = StubLanguageModelManager()
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(thaiPair)
        manager.statuses[thaiPair.id] = .installed
        await viewModel.refresh()

        #expect(viewModel.status(of: thaiPair) == .downloading(progress: nil))
    }

    // MARK: Language detection model

    private let detection = LanguageModel.detectionModels[0]

    @Test func theDetectionModelIsListedAndRefreshed() async {
        let manager = StubLanguageModelManager()
        manager.statuses[detection.id] = .installed
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())
        #expect(viewModel.detectionModels == [detection])
        await viewModel.refresh()
        #expect(viewModel.status(of: detection) == .installed)
    }

    @Test func downloadingTheDetectionModelInstallsItAndCanBeRemoved() async {
        let manager = StubLanguageModelManager()
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())
        #expect(!viewModel.canRemove(detection))

        await viewModel.download(detection)

        #expect(manager.detectionInstalls == 1)
        #expect(viewModel.status(of: detection) == .installed)
        #expect(viewModel.canRemove(detection))

        await viewModel.remove(detection)

        #expect(manager.detectionRemovals == 1)
        #expect(viewModel.status(of: detection) == .notInstalled)
    }

    @Test func aDetectionDownloadStartedElsewhereIsFollowedUntilItFinishes() async {
        let manager = StubLanguageModelManager()
        manager.statuses[detection.id] = .downloading(progress: 0.3)
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.refresh()
        for _ in 0..<200 where viewModel.status(of: detection) != .installed {
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The row joined the running install and ended on "installed", not stuck on "Downloading…".
        #expect(manager.detectionInstalls == 1)
        #expect(viewModel.status(of: detection) == .installed)
        #expect(viewModel.canRemove(detection))
    }

    @Test func aDownloadThatEndedBeforeItWasFollowedIsNotStartedAgain() async {
        let manager = StubLanguageModelManager()
        // The first read says a download is running; by the time the row looks again it has failed.
        manager.queuedStatuses[detection.id] = [.downloading(progress: 0.3)]
        manager.statuses[detection.id] = .notInstalled
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.refresh()
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(10)) }

        #expect(manager.detectionInstalls == 0)
        #expect(viewModel.status(of: detection) == .notInstalled)
    }

    @Test func aFailedDetectionInstallCanStillBeCleared() async {
        let manager = StubLanguageModelManager()
        manager.detectionError = LanguageDetectionModelError.unusable
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(detection)
        #expect(viewModel.canRemove(detection))
        await viewModel.remove(detection)
        #expect(manager.detectionRemovals == 1)
        #expect(viewModel.status(of: detection) == .notInstalled)
    }

    @Test func aFailedDetectionDownloadIsReportedAndRetryable() async {
        let manager = StubLanguageModelManager()
        manager.detectionError = LanguageDetectionModelError.incompleteDownload
        let viewModel = LanguageModelsViewModel(manager: manager, listening: thaiListener())

        await viewModel.download(detection)
        guard case .failed = viewModel.status(of: detection) else {
            Issue.record("expected failed status"); return
        }

        manager.detectionError = nil
        await viewModel.download(detection)
        #expect(viewModel.status(of: detection) == .installed)
    }
}
