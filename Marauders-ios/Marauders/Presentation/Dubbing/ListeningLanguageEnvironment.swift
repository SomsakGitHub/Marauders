//
//  ListeningLanguageEnvironment.swift
//  Marauders
//

import SwiftUI

extension EnvironmentValues {
    /// The viewer's listening language, which the screens that offer AI audio share. `AppRootView` installs the real
    /// store from the composition root; `nil` until something does.
    @Entry var listeningLanguageStore: ListeningLanguageStore? = nil

    /// The view model of the listening-language picker, which Settings, the feed and the clip player share.
    /// `AppRootView` installs it from the composition root; `nil` until something does.
    @Entry var listeningLanguagePicker: ListeningLanguagePickerViewModel? = nil
}

extension ListeningLanguageStore {
    /// A store that stands alone, over the saved settings: what a Release build falls back on when none was installed,
    /// and what a preview uses.
    static func standalone() -> ListeningLanguageStore {
        ListeningLanguageStore(memo: DetectedLanguageMemo())
    }
}
