//
//  UploadVideoView.swift
//  Marauders
//

import PhotosUI
import SwiftUI
import UIKit

struct UploadVideoView: View {
    @Bindable var viewModel: UploadVideoViewModel

    @Environment(\.openURL) private var openURL
    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingClipLocationPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label(
                            viewModel.uploadFileURL == nil ? "Choose from Library" : "Change Video",
                            systemImage: "film"
                        )
                    }
                    .accessibilityIdentifier("upload.pickVideo")
                    .disabled(viewModel.isUploading || viewModel.isPreparing)

                    if viewModel.isPreparing {
                        HStack {
                            ProgressView()
                            Text("Preparing video…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let uploadFileURL = viewModel.uploadFileURL {
                        Text(uploadFileURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if pickerItem != nil {
                        HStack {
                            ProgressView()
                            Text("Preparing file…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Details") {
                    TextField("Caption", text: $viewModel.caption, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .accessibilityIdentifier("upload.caption")
                }
                .disabled(viewModel.isUploading || viewModel.isPreparing)

                if viewModel.showsSpokenLanguagePicker {
                    Section {
                        Picker("Language in clip", selection: spokenLanguageSelection) {
                            Text("Automatic").tag(String?.none)
                            ForEach(SpokenLanguageCatalog.options(including: viewModel.spokenLanguageCode)) { option in
                                Text(option.name).tag(Optional(option.code))
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("upload.spokenLanguage")
                    } footer: {
                        Text(spokenLanguageFooter)
                    }
                    .disabled(viewModel.isUploading)
                }

                Section("Clip location") {
                    if let clipLocation = viewModel.clipLocation {
                        Text(
                            String(
                                format: "%.5f, %.5f",
                                clipLocation.latitude,
                                clipLocation.longitude
                            )
                        )
                        .font(.caption.monospaced())
                        .accessibilityIdentifier("upload.clipLocation.value")
                    } else {
                        Text("Required before you can upload")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isShowingClipLocationPicker = true
                    } label: {
                        Label("Search or Drop Pin", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(viewModel.isUploading || viewModel.isPreparing)
                    .accessibilityIdentifier("upload.chooseClipLocation")

                    Button {
                        viewModel.setClipLocationFromCurrentPositionTapped()
                    } label: {
                        if viewModel.isResolvingClipLocation {
                            HStack {
                                ProgressView()
                                Text("Getting location…")
                            }
                        } else {
                            Label("Use Current Location", systemImage: "location.fill")
                        }
                    }
                    .disabled(viewModel.isUploading || viewModel.isPreparing)
                    .accessibilityIdentifier("upload.useCurrentClipLocation")
                }

                Section {
                    Button {
                        Task { await viewModel.upload() }
                    } label: {
                        if viewModel.isUploading {
                            HStack {
                                ProgressView()
                                Text("Uploading…")
                            }
                        } else {
                            Text("Upload to Feed")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!viewModel.canUpload)
                }

                if let statusMessage = viewModel.statusMessage {
                    Section("Status") {
                        CopyableStatusBanner(message: statusMessage, isSuccess: viewModel.isSuccess)
                    }
                }
            }
            .accessibilityIdentifier("upload.root")
            .navigationTitle("Upload")
            .onChange(of: pickerItem) { _, newItem in
                Task { await loadPickerItem(newItem) }
            }
            .onChange(of: viewModel.uploadFileURL) { _, url in
                if url == nil, viewModel.isSuccess {
                    pickerItem = nil
                }
            }
            .confirmationDialog(
                "Use your location?",
                isPresented: $viewModel.showClipLocationPrePrompt,
                titleVisibility: .visible
            ) {
                Button("Continue") {
                    viewModel.confirmClipLocationPermissionRequest()
                }
                Button("Not Now", role: .cancel) {
                    viewModel.cancelClipLocationPermissionRequest()
                }
            } message: {
                Text("We use your location to tag where this clip was recorded.")
            }
            .sheet(isPresented: $isShowingClipLocationPicker) {
                ClipLocationPickerView(initialLocation: viewModel.clipLocation) { location in
                    viewModel.applyClipLocation(location)
                }
            }
            .alert("Location Access Off", isPresented: $viewModel.showClipLocationDeniedAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn on location for Marauders in Settings to tag your clip.")
            }
        }
    }

    private var spokenLanguageSelection: Binding<String?> {
        Binding(
            get: { viewModel.spokenLanguageCode },
            set: { viewModel.chooseSpokenLanguage($0) }
        )
    }

    private var spokenLanguageFooter: String {
        switch viewModel.spokenLanguageOrigin {
        case .chosen:
            "You chose this language. Viewers' iPhones use it instead of working it out themselves."
        case .unset:
            "Optional. Left on Automatic, each viewer's iPhone works out the language when they listen."
        }
    }

    private func loadPickerItem(_ item: PhotosPickerItem?) async {
        guard let item else {
            viewModel.resetPickedFile()
            return
        }
        AppLog.info("upload", "picker item selected — loading transferable")
        do {
            guard let video = try await item.loadTransferable(type: PickedVideoFile.self) else {
                viewModel.statusMessage = "Couldn’t read video — try a shorter clip"
                AppLog.error("upload", "loadTransferable returned nil")
                return
            }
            await viewModel.prepare(sourceURL: video.url)
        } catch {
            viewModel.statusMessage = error.localizedDescription
            AppLog.error("upload", "loadTransferable failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    UploadVideoView(viewModel: AppDependencyContainer().uploadViewModel)
}
