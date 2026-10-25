//
//  SettingsView.swift
//  Marauders
//

import SwiftUI

struct SettingsView: View {
    @Bindable var languageModels: LanguageModelsViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LanguageModelsView(viewModel: languageModels)
                    } label: {
                        Label("Language models", systemImage: "character.bubble")
                    }
                    .accessibilityIdentifier("settings.languageModels")
                } footer: {
                    Text("Download on-device models for AI Thai dubbing and language detection.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("settings.root")
    }
}

#Preview {
    SettingsView(languageModels: LanguageModelsViewModel(manager: NoopLanguageModelManager()))
}
