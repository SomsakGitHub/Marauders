//
//  MapSearchBar.swift
//  Marauders
//

import SwiftUI

/// The floating search pill shown at the top of the map.
struct MapSearchBar: View {
    @Binding var text: String
    var prompt: String = String(localized: "Search clips")
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .floatingChrome(in: Capsule())
        .accessibilityIdentifier("map.search")
    }
}
