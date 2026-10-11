//
//  MapCountryFilterSheet.swift
//  Marauders
//

import SwiftUI

/// Lets the user pick which country's posts appear on the map (`nil` = all).
struct MapCountryFilterSheet: View {
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private let countries = CountryCatalog.all()

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack {
                        Label("All countries", systemImage: "globe")
                        Spacer()
                        if selection == nil {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("map.country.all")

                ForEach(filteredCountries) { country in
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
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("map.country.\(country.code)")
                }
            }
            .searchable(text: $query, prompt: "Search country")
            .navigationTitle("Show posts from")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .accessibilityIdentifier("map.country.list")
        }
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
