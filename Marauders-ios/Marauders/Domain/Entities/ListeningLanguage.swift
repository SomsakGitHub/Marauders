//
//  ListeningLanguage.swift
//  Marauders
//

import Foundation

/// A language a viewer can have clips dubbed into. Each is a BCP-47 base language that Apple
/// Translation can produce; viewers also need a system speech voice for it.
struct ListeningLanguage: Hashable, Identifiable, Sendable {
    let code: String
    var id: String { code }

    /// Mirrors the API's allowed dubbing languages (`DUBBING_LANGUAGES` in the backend).
    static let codes = [
        "ar", "da", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
        "nb", "nl", "pl", "pt", "ru", "sv", "th", "tr", "uk", "vi", "zh"
    ]
    static let all = codes.map { ListeningLanguage(code: $0) }
    static let english = ListeningLanguage(code: "en")
    static let spanish = ListeningLanguage(code: "es")
    static let thai = ListeningLanguage(code: "th")

    private init(code: String) { self.code = code }

    /// Names follow the language the app's interface is shown in, so a sentence never mixes in
    /// a third language when the device language has no translation of the app.
    static var interfaceLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// Parses a locale identifier such as "en-TH", "zh-Hans-CN" or "no"; nil when unsupported.
    init?(identifier: String) {
        var base = Locale(identifier: identifier).language.languageCode?.identifier.lowercased() ?? ""
        // Apple Translation and the system voices use Bokmål for Norwegian.
        if base == "no" || base == "nn" { base = "nb" }
        guard Self.codes.contains(base) else { return nil }
        self.init(code: base)
    }

    /// The name in the viewer's language, for lists ("Thai", "ไทย").
    func displayName(in locale: Locale = ListeningLanguage.interfaceLocale) -> String {
        (locale.localizedString(forLanguageCode: code) ?? code).localizedCapitalized
    }

    /// The language's own name, shown next to the translated one ("ไทย", "Español").
    var nativeName: String {
        (Locale(identifier: code).localizedString(forLanguageCode: code) ?? code).localizedCapitalized
    }

    /// The name used inside a sentence, such as "Listen in Thai"; some languages keep it lowercase.
    func sentenceName(in locale: Locale = ListeningLanguage.interfaceLocale) -> String {
        locale.localizedString(forLanguageCode: code) ?? code
    }
}
