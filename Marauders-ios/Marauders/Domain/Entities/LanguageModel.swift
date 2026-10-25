//
//  LanguageModel.swift
//  Marauders
//

import Foundation

/// An on-device Apple language asset the app can use for AI dubbing and language detection.
struct LanguageModel: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Apple Translation pair (BCP-47 language codes).
        case translation(source: String, target: String)
        /// Apple SpeechTranscriber locale identifier.
        case speech(locale: String)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String

    /// Translation pairs the viewer may need: every dubbing source into each listening language.
    static func translationModels(
        for targets: [ListeningLanguage],
        locale: Locale = ListeningLanguage.interfaceLocale
    ) -> [LanguageModel] {
        var models: [LanguageModel] = []
        for target in targets {
            for source in DubbingSourceLanguage.allCases where source.translationCode != target.code {
                models.append(.init(
                    id: "translation.\(source.translationCode)-\(target.code)",
                    kind: .translation(source: source.translationCode, target: target.code),
                    title: "\(source.displayName(in: locale)) → \(target.displayName(in: locale))",
                    detail: String(localized: "Used by AI dubbing")
                ))
            }
        }
        return models
    }

    static let speechModels: [LanguageModel] = [
        .init(id: "speech.en-US", kind: .speech(locale: "en-US"),
              title: ListeningLanguage.english.displayName(), detail: String(localized: "Speech recognition")),
        .init(id: "speech.th-TH", kind: .speech(locale: "th-TH"),
              title: ListeningLanguage.thai.displayName(), detail: String(localized: "Speech recognition")),
        .init(id: "speech.es-ES", kind: .speech(locale: "es-ES"),
              title: ListeningLanguage.spanish.displayName(), detail: String(localized: "Detects Spanish on upload and transcribes it for dubbing"))
    ]
}

enum LanguageModelStatus: Equatable, Sendable {
    case checking
    case installed
    case notInstalled
    /// `nil` progress means the system does not report progress (e.g. Translation).
    case downloading(progress: Double?)
    case unsupported
    case failed(String)
}
