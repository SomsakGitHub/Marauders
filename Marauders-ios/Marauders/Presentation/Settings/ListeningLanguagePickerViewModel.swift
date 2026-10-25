//
//  ListeningLanguagePickerViewModel.swift
//  Marauders
//

import Foundation
import Observation

@MainActor
@Observable
final class ListeningLanguagePickerViewModel {
    struct Row: Identifiable, Equatable {
        let language: ListeningLanguage
        let name: String
        let nativeName: String
        let isSelected: Bool
        let isAvailable: Bool
        var id: String { language.code }
    }

    private let store: ListeningLanguageStore
    private let availability: any ListeningLanguageAvailability
    private(set) var unavailable: Set<String> = []
    private(set) var isChecking = true

    init(
        store: ListeningLanguageStore = .shared,
        availability: any ListeningLanguageAvailability = SystemListeningLanguageAvailability()
    ) {
        self.store = store
        self.availability = availability
    }

    var isAutomatic: Bool { store.explicit == nil }

    /// What "Automatic" resolves to right now, for the row's subtitle.
    var automaticName: String? { store.supportedDeviceLanguages.first?.displayName() }

    /// Value shown on the Settings row.
    var summary: String {
        if let explicit = store.explicit { return explicit.displayName() }
        if let automatic = automaticName { return String(localized: "Automatic · \(automatic)") }
        return String(localized: "Not set")
    }

    var rows: [Row] {
        let selected = store.explicit
        return ListeningLanguage.all
            .map { language in
                Row(language: language, name: language.displayName(), nativeName: language.nativeName,
                    isSelected: language == selected, isAvailable: !unavailable.contains(language.code))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refresh() async {
        let result = await availability.unavailableLanguageCodes()
        // When every language looks unavailable the check itself is not working (for example in
        // the simulator), and disabling every row would leave the viewer unable to choose.
        unavailable = result.isSuperset(of: ListeningLanguage.codes) ? [] : result
        isChecking = false
    }

    func chooseAutomatic() {
        store.choose(nil)
    }

    /// Returns false when this iPhone can't serve the language, leaving the choice unchanged.
    @discardableResult
    func choose(_ language: ListeningLanguage) -> Bool {
        guard !unavailable.contains(language.code) else { return false }
        store.choose(language)
        return true
    }
}
