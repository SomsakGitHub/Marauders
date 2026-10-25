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
    var installError: Error?
    var installed: [String] = []
    var removed: [String] = []

    func status(of model: LanguageModel) async -> LanguageModelStatus { statuses[model.id] ?? .notInstalled }

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
}
