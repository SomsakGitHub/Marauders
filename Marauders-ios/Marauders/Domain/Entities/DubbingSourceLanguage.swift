//
//  DubbingSourceLanguage.swift
//  Marauders
//

import Foundation

/// Languages the on-device pipeline can transcribe and translate into Thai.
enum DubbingSourceLanguage: String, Hashable, Sendable {
    case english
    case spanish

    /// BCP-47 language code for Apple Translation.
    var translationCode: String {
        switch self {
        case .english: "en"
        case .spanish: "es"
        }
    }

    var speechLocale: String {
        switch self {
        case .english: "en-US"
        case .spanish: "es-ES"
        }
    }

    /// Thai name, used in progress and error messages.
    var thaiName: String {
        switch self {
        case .english: "อังกฤษ"
        case .spanish: "สเปน"
        }
    }

    /// Picks the language from what the uploader chose or the device detected. Clips with
    /// no usable language keep the original English behavior.
    init(spokenLanguage: SpokenLanguageAssessment?) {
        let code = spokenLanguage?.knownCode?.split(separator: "-").first.map(String.init)
        self = code == "es" ? .spanish : .english
    }
}
