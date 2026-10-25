//
//  SpokenLanguageCatalog.swift
//  Marauders
//

import Foundation

struct SpokenLanguageOption: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }
}

/// Languages offered when an uploader tells us what is spoken in a clip. Choosing one
/// only labels the clip; dubbing support for each language is decided elsewhere.
enum SpokenLanguageCatalog {
    /// Lowercase BCP-47 language codes, matching what the API accepts.
    static let codes = [
        "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fil", "fr",
        "he", "hi", "hr", "hu", "id", "it", "ja", "ko", "ms", "nb", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "vi", "yue", "zh"
    ]

    /// The catalog sorted by localized name, plus `current` when it isn't one of them
    /// (for example a detected `zh-hans`), so the picker never shows a selection without a row.
    static func options(including current: String? = nil, locale: Locale = .current) -> [SpokenLanguageOption] {
        var all = codes
        if let current = current?.lowercased(), !current.isEmpty, !all.contains(current) {
            all.append(current)
        }
        return all
            .map { SpokenLanguageOption(code: $0, name: name(for: $0, locale: locale)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func name(for code: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? code
    }
}
