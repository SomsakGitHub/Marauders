//
//  SettingsView.swift
//  Marauders
//

import SwiftUI

struct SettingsView: View {
    @Bindable var languageModels: LanguageModelsViewModel
    @State private var listeningPicker = ListeningLanguagePickerViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ListeningLanguagePickerView(viewModel: listeningPicker)
                    } label: {
                        LabeledContent {
                            Text(listeningPicker.summary)
                        } label: {
                            Label("Listening language", systemImage: "ear")
                        }
                    }
                    .accessibilityIdentifier("settings.listeningLanguage")
                } footer: {
                    Text("Clips in other languages can be dubbed into this language with AI on your iPhone.")
                }

                Section {
                    NavigationLink {
                        LanguageModelsView(viewModel: languageModels)
                    } label: {
                        Label("Language models", systemImage: "character.bubble")
                    }
                    .accessibilityIdentifier("settings.languageModels")
                } footer: {
                    Text("Download on-device models for AI dubbing and language detection.")
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
