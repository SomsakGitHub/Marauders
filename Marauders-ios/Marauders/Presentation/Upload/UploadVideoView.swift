//
//  UploadVideoView.swift
//  Marauders
//

import PhotosUI
import SwiftUI

struct UploadVideoView: View {
    @Bindable var viewModel: UploadVideoViewModel

    @State private var pickerItem: PhotosPickerItem?

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
                            Text("Converting to MP4…")
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
