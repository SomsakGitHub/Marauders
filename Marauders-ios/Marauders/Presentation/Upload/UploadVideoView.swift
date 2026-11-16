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
                        .lineLimit(1...4)
                        .accessibilityIdentifier("upload.caption")
                }
                .disabled(viewModel.isUploading || viewModel.isPreparing)

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
                            uploadingLabel
                        } else {
                            Text("Upload to Feed")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!viewModel.canUpload)
                }

                // A failed upload stays on screen with its buttons even when something else cleared the status line,
                // because the viewer has no other way to act on it.
                if let statusMessage = viewModel.statusMessage ?? viewModel.failedUpload?.message {
                    Section("Status") {
                        CopyableStatusBanner(message: statusMessage, isSuccess: viewModel.isSuccess)
                        if let failedUpload = viewModel.failedUpload {
                            if failedUpload.canRetry {
                                Button("Try again") {
                                    Task { await viewModel.retryUpload() }
                                }
                                .accessibilityIdentifier("upload.retry")
                            }
                            Button("Choose another video") {
                                Task { await viewModel.chooseAnotherVideo() }
                            }
                            .accessibilityIdentifier("upload.chooseAnother")
                        }
                    }
                }
            }
            .accessibilityIdentifier("upload.root")
            .navigationTitle("Upload")
            .onChange(of: pickerItem) { _, newItem in
                Task { await loadPickerItem(newItem) }
            }
            .onChange(of: viewModel.uploadFileURL) { _, url in
                // The clip leaves the form when the uploader takes it, so the picker lets go of it too.
                if url == nil, viewModel.isUploading || viewModel.isSuccess {
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

    /// What the Upload button shows while a clip uploads: a bar that fills as the body is sent, and a spinner once every
    /// byte is out and the app waits for the Worker's answer.
    @ViewBuilder
    private var uploadingLabel: some View {
        if let label = viewModel.uploadProgressLabel {
            if viewModel.isFinishingUpload {
                HStack {
                    ProgressView()
                        .accessibilityIdentifier("upload.progress")
                    Text(label)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: viewModel.uploadProgress ?? 0)
                        .accessibilityIdentifier("upload.progress")
                    Text(label)
                }
            }
        } else {
            HStack {
                ProgressView()
                Text("Uploading…")
            }
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
