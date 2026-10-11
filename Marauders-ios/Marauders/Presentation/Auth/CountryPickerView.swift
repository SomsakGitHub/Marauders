//
//  CountryPickerView.swift
//  Marauders
//

import SwiftUI

/// Searchable list of countries. Writes the chosen ISO code back to `selection`.
struct CountryPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private let countries = CountryCatalog.all()

    var body: some View {
        List(filteredCountries) { country in
            Button {
                selection = country.code
                dismiss()
            } label: {
                HStack {
                    Text(country.flagEmoji)
                    Text(country.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if country.code == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("country.\(country.code)")
        }
        .searchable(text: $query, prompt: "Search country")
        .navigationTitle("Country")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("country.list")
    }

    private var filteredCountries: [Country] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return countries }
        return countries.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.code.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}
