//
//  ListeningLanguagePickerView.swift
//  Marauders
//

import SwiftUI

/// Lets a viewer pick the language they want clips dubbed into.
struct ListeningLanguagePickerView: View {
    @Bindable var viewModel: ListeningLanguagePickerViewModel
    /// Called after a choice is made, for example to close a sheet and start dubbing.
    var onChosen: (() -> Void)?

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.chooseAutomatic()
                    onChosen?()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic")
                            Text(automaticSubtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if viewModel.isAutomatic { checkmark }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("listeningLanguage.automatic")
            } footer: {
                Text("Clips spoken in another language are dubbed into this language on your iPhone.")
            }

            Section("Languages") {
                ForEach(viewModel.rows) { row in
                    Button {
                        if viewModel.choose(row.language) { onChosen?() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                if row.nativeName != row.name {
                                    Text(row.nativeName)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if !row.isAvailable {
                                    Text("Not available on this iPhone")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if row.isSelected { checkmark }
                        }
                    }
                    .foregroundStyle(row.isAvailable ? .primary : .secondary)
                    .disabled(!row.isAvailable)
                    .accessibilityIdentifier("listeningLanguage.\(row.language.code)")
                }
            }
        }
        .navigationTitle("Listening language")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("listeningLanguage.root")
        .task { await viewModel.refresh() }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private var automaticSubtitle: String {
        if let name = viewModel.automaticName { return String(localized: "Uses your device languages · \(name)") }
        return String(localized: "None of your device languages is supported yet")
    }
}

#Preview {
    NavigationStack {
        ListeningLanguagePickerView(viewModel: ListeningLanguagePickerViewModel(availability: NoopListeningLanguageAvailability()))
    }
}
