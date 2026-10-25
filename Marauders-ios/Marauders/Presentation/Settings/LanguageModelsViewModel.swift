//
//  LanguageModelsViewModel.swift
//  Marauders
//

import Foundation
import Observation
@preconcurrency import Translation

@MainActor
@Observable
final class LanguageModelsViewModel {
    private(set) var statuses: [LanguageModel.ID: LanguageModelStatus] = [:]
    /// Set while a translation pair is being downloaded; the view hands it to `.translationTask`.
    private(set) var translationConfiguration: TranslationSession.Configuration?

    private let manager: any LanguageModelManaging
    private let listening: ListeningLanguageStore
    private var translationModel: LanguageModel?

    init(
        manager: any LanguageModelManaging = AppleLanguageModelManager(),
        listening: ListeningLanguageStore = .shared
    ) {
        self.manager = manager
        self.listening = listening
    }

    /// Pairs follow the viewer's listening language, so the list changes when they pick another.
    var translationModels: [LanguageModel] { LanguageModel.translationModels(for: listening.possibleTargets) }
    var speechModels: [LanguageModel] { LanguageModel.speechModels }

    func status(of model: LanguageModel) -> LanguageModelStatus {
        statuses[model.id] ?? .checking
    }

    func canRemove(_ model: LanguageModel) -> Bool {
        if case .speech = model.kind { return status(of: model) == .installed }
        return false
    }

    func refresh() async {
        let models = (translationModels + speechModels).filter { !isDownloading($0) }
        // Each lookup is independent; start them together instead of one after another.
        let lookups = models.map { model in
            Task { (model, await self.manager.status(of: model)) }
        }
        for lookup in lookups {
            let (model, status) = await lookup.value
            // A download may have started while the lookup was in flight.
            if !isDownloading(model) { statuses[model.id] = status }
        }
    }

    /// Leaving the screen before the system prompt appears would otherwise leave the row
    /// stuck on "Downloading…", because `refresh()` skips rows that are downloading.
    func abandonTranslationDownload() async {
        guard let model = translationModel else { return }
        translationModel = nil
        translationConfiguration = nil
        statuses[model.id] = await manager.status(of: model)
    }

    func download(_ model: LanguageModel) async {
        guard !isDownloading(model) else { return }
        switch model.kind {
        case let .translation(source, target):
            guard translationModel == nil else { return }
            translationModel = model
            statuses[model.id] = .downloading(progress: nil)
            translationConfiguration = .init(source: Locale.Language(identifier: source),
                                             target: Locale.Language(identifier: target))
        case let .speech(locale):
            statuses[model.id] = .downloading(progress: 0)
            do {
                try await manager.installSpeechModel(locale: locale) { [weak self] value in
                    guard let self, case .downloading = self.statuses[model.id] else { return }
                    self.statuses[model.id] = .downloading(progress: value)
                }
                statuses[model.id] = await manager.status(of: model)
            } catch {
                statuses[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs inside the view's `.translationTask`; Apple shows its own download sheet.
    func prepareTranslation(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            await translationDownloadFinished(error: nil)
        } catch {
            await translationDownloadFinished(error: error)
        }
    }

    func translationDownloadFinished(error: Error?) async {
        guard let model = translationModel else { return }
        translationModel = nil
        translationConfiguration = nil
        if error is CancellationError {
            statuses[model.id] = await manager.status(of: model)
        } else if let error {
            // Dismissing the system download sheet also throws; re-check before reporting failure.
            let actual = await manager.status(of: model)
            statuses[model.id] = actual == .installed ? actual : .failed(error.localizedDescription)
        } else {
            statuses[model.id] = await manager.status(of: model)
        }
    }

    func remove(_ model: LanguageModel) async {
        guard case let .speech(locale) = model.kind, canRemove(model) else { return }
        _ = await manager.removeSpeechModel(locale: locale)
        statuses[model.id] = await manager.status(of: model)
    }

    private func isDownloading(_ model: LanguageModel) -> Bool {
        if case .downloading = statuses[model.id] { return true }
        return false
    }
}
