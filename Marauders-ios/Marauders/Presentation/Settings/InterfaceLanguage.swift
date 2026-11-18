//
//  InterfaceLanguage.swift
//  Marauders
//

import Foundation

/// The language the app's own texts are in. iOS chooses it: from the iPhone's list of languages, or from the language
/// the viewer set for Marauders alone on the app's page in iOS Settings. The app cannot change it itself.
enum InterfaceLanguage {
    /// The language's name in its own words ("English", "ไทย"), the way iOS Settings lists languages.
    static func currentName(preferredLocalizations: [String] = Bundle.main.preferredLocalizations) -> String {
        guard let code = preferredLocalizations.first(where: { $0 != "Base" }) else { return english }
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forLanguageCode: code),
            name.caseInsensitiveCompare(code) != .orderedSame
        else { return english }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The app's texts are English wherever no other language applies. A language's own name is the same in every
    /// language, so this one is not localized.
    private static let english = "English"
}
