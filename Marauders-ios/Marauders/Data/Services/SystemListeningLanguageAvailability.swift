import Foundation
@preconcurrency import Translation

struct SystemListeningLanguageAvailability: ListeningLanguageAvailability {
    func unavailableLanguageCodes() async -> Set<String> {
        let candidates = SpeechVoiceCatalog.candidates()
        let availability = LanguageAvailability()
        var unavailable = Set<String>()
        for language in ListeningLanguage.all {
            guard SpeechVoiceCatalog.bestLanguageTag(for: language, among: candidates) != nil else {
                unavailable.insert(language.code)
                continue
            }
            // A language is usable when at least one dubbing source translates into it.
            var reachable = false
            for source in DubbingSourceLanguage.allCases where source.translationCode != language.code {
                let status = await availability.status(
                    from: Locale.Language(identifier: source.translationCode),
                    to: Locale.Language(identifier: language.code)
                )
                if status != .unsupported { reachable = true; break }
            }
            if !reachable { unavailable.insert(language.code) }
        }
        return unavailable
    }
}
