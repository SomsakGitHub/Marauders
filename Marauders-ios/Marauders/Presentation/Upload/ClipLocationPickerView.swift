//
//  ClipLocationPickerView.swift
//  Marauders
//

import MapKit
import SwiftUI

struct ClipLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
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

                MapReader { proxy in
                    Map(position: $pickerModel.mapPosition, interactionModes: .all) {
                        Marker("Clip", coordinate: pickerModel.selectedCoordinate)
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .onTapGesture { screenPoint in
                        guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                        pickerModel.movePin(to: coordinate)
                    }
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
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search places", text: $pickerModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .onSubmit {
                    Task { await pickerModel.search() }
                }
                .accessibilityIdentifier("upload.clipLocationPicker.searchField")

            Button {
                Task { await pickerModel.search() }
            } label: {
                if pickerModel.isSearching {
                    ProgressView()
                } else {
                    Text("Search")
                }
            }
            .disabled(pickerModel.isSearching)
            .accessibilityIdentifier("upload.clipLocationPicker.searchButton")
        }
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
