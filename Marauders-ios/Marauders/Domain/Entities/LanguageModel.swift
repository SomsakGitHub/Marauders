//
//  LanguageModel.swift
//  Marauders
//

import Foundation

/// An on-device Apple language asset the app can use for Thai dubbing and language detection.
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

    static let translationModels: [LanguageModel] = [
        .init(id: "translation.en-th", kind: .translation(source: "en", target: "th"),
              title: "English → Thai", detail: "Used by AI Thai dubbing"),
        .init(id: "translation.es-th", kind: .translation(source: "es", target: "th"),
              title: "Spanish → Thai", detail: "Optional")
    ]

    static let speechModels: [LanguageModel] = [
        .init(id: "speech.en-US", kind: .speech(locale: "en-US"),
              title: "English", detail: "Speech recognition"),
        .init(id: "speech.th-TH", kind: .speech(locale: "th-TH"),
              title: "Thai", detail: "Speech recognition"),
        .init(id: "speech.es-ES", kind: .speech(locale: "es-ES"),
              title: "Spanish", detail: "Used to detect Spanish clips on upload")
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
