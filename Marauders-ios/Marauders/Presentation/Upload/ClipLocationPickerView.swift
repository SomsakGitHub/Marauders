//
//  ClipLocationPickerView.swift
//  Marauders
//

import MapKit
import SwiftUI

struct ClipLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchIsFocused: Bool
    @State private var pickerModel: ClipLocationPickerViewModel

    let onConfirm: (ClipLocation) -> Void

    init(initialLocation: ClipLocation?, onConfirm: @escaping (ClipLocation) -> Void) {
        _pickerModel = State(initialValue: ClipLocationPickerViewModel(initial: initialLocation))
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                if let searchError = pickerModel.searchError {
                    Text(searchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                if !pickerModel.searchResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(pickerModel.searchResults) { result in
                                Button {
                                    pickerModel.select(result)
                                    searchIsFocused = false
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "mappin.circle.fill").font(.title2)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(result.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                            if !result.address.isEmpty {
                                                Text(result.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.left").font(.caption)
                                    }
                                    .padding(12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                    .accessibilityIdentifier("upload.clipLocationPicker.results")
                }

                MapReader { proxy in
                    Map(position: $pickerModel.mapPosition, interactionModes: .all) {
                        Marker("Clip", coordinate: pickerModel.selectedCoordinate)
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .onTapGesture { screenPoint in
                        guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                        searchIsFocused = false
                        pickerModel.cancelSearch()
                        pickerModel.movePin(to: coordinate)
                    }
                }

                if let name = pickerModel.selectedPlaceName {
                    Text(name).font(.subheadline.weight(.medium)).padding(.top, 8)
                }

                Text(coordinateLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
            .navigationTitle("Clip Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Pin") {
                        guard let location = pickerModel.confirmedClipLocation() else { return }
                        onConfirm(location)
                        dismiss()
                    }
                    .accessibilityIdentifier("upload.clipLocationPicker.confirm")
                }
            }
        }
        .accessibilityIdentifier("upload.clipLocationPicker")
        .task(id: pickerModel.searchQuery) {
            pickerModel.cancelSearch()
            let query = pickerModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 2, query.count <= 120 else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            await pickerModel.search()
        }
        .onDisappear { pickerModel.cancelSearch() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search places or addresses", text: $pickerModel.searchQuery)
                .focused($searchIsFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit {
                    Task { await pickerModel.search() }
                }
                .accessibilityIdentifier("upload.clipLocationPicker.searchField")

            if !pickerModel.searchQuery.isEmpty {
                Button {
                    pickerModel.searchQuery = ""
                    pickerModel.cancelSearch()
                    searchIsFocused = true
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .accessibilityLabel("Clear search")
            }

            Button {
                Task { await pickerModel.search() }
            } label: {
                if pickerModel.isSearching {
                    ProgressView()
                } else {
                    Text("Search")
                }
            }
            .disabled(pickerModel.isSearching || pickerModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            .accessibilityIdentifier("upload.clipLocationPicker.searchButton")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var coordinateLabel: String {
        String(
            format: "%.5f, %.5f — tap the map to move the pin",
            pickerModel.selectedCoordinate.latitude,
            pickerModel.selectedCoordinate.longitude
        )
    }
}

#Preview {
    ClipLocationPickerView(initialLocation: nil) { _ in }
}
