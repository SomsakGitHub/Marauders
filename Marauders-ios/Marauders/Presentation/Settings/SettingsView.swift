//
//  SettingsView.swift
//  Marauders
//

import SwiftUI

struct SettingsView: View {
    @Bindable var languageModels: LanguageModelsViewModel
    /// The viewer's location sharing; here so it can be turned off even when location access is off and the map closed.
    var friendLocations: FriendLocationsViewModel? = nil
    var isSignedIn = false
    @State private var listeningPicker = ListeningLanguagePickerViewModel()
    @State private var isConfirmingSharing = false
    @State private var sharingError: String?

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

                if isSignedIn, let friendLocations {
                    Section {
                        Toggle(isOn: sharingBinding(friendLocations)) {
                            Label("Share location with mutual followers", systemImage: "location.circle")
                        }
                        .disabled(friendLocations.sharing == nil || friendLocations.isChangingSharing)
                        .accessibilityIdentifier("settings.locationSharing")
                    } header: {
                        Text("Location sharing")
                    } footer: {
                        Text("People you follow who follow you back see where you last used the app while you both share. Turning it off takes you off their maps at once.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Share your location?", isPresented: $isConfirmingSharing) {
                Button("Share location") {
                    Task { sharingError = await friendLocations?.setSharing(true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("People you follow who follow you back and share their location too will see where you last used the app, and you'll see where they are. You can turn it off any time.")
            }
            .alert("Couldn't change location sharing", isPresented: sharingErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sharingError ?? "")
            }
        }
        .accessibilityIdentifier("settings.root")
    }

    /// On asks first, as the map's switch does; off goes through at once.
    private func sharingBinding(_ friendLocations: FriendLocationsViewModel) -> Binding<Bool> {
        Binding(
            get: { friendLocations.sharing == true },
            set: { wantsSharing in
                if wantsSharing {
                    isConfirmingSharing = true
                } else {
                    Task { sharingError = await friendLocations.setSharing(false) }
                }
            }
        )
    }

    private var sharingErrorBinding: Binding<Bool> {
        Binding(
            get: { sharingError != nil },
            set: { if !$0 { sharingError = nil } }
        )
    }
}

#Preview {
    SettingsView(languageModels: LanguageModelsViewModel(manager: NoopLanguageModelManager()))
}
