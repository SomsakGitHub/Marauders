//
//  AppleLanguageModelManager.swift
//  Marauders
//

import Foundation
import Speech
@preconcurrency import Translation

struct AppleLanguageModelManager: LanguageModelManaging {
    func status(of model: LanguageModel) async -> LanguageModelStatus {
        switch model.kind {
        case let .translation(source, target):
            let availability = LanguageAvailability()
            switch await availability.status(from: Locale.Language(identifier: source),
                                             to: Locale.Language(identifier: target)) {
            case .installed: return .installed
            case .supported: return .notInstalled
            case .unsupported: return .unsupported
            @unknown default: return .unsupported
            }
        case let .speech(identifier):
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
            else { return .unsupported }
            switch await AssetInventory.status(forModules: [Self.transcriber(for: locale)]) {
            case .installed: return .installed
            case .unsupported: return .unsupported
            default: return .notInstalled
            }
        }
    }

    func installSpeechModel(locale identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
        else { throw LanguageModelError.unsupported }
        let transcriber = Self.transcriber(for: locale)
        if await !AssetInventory.reservedLocales.contains(locale) {
            guard try await AssetInventory.reserve(locale: locale) else { throw LanguageModelError.reservationLimit }
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { observer.cancel() }
        try await request.downloadAndInstall()
    }

    func removeSpeechModel(locale identifier: String) async -> Bool {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
        else { return false }
        return await AssetInventory.release(reservedLocale: locale)
    }

    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.transcriptionConfidence])
    }
}

enum LanguageModelError: LocalizedError {
    case unsupported
    case reservationLimit

    var errorDescription: String? {
        switch self {
        case .unsupported: "This language isn't supported on this device."
        case .reservationLimit: "The system limit for downloaded speech languages was reached. Remove another language first."
        }
    }
}
