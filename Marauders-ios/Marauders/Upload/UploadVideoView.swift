//
//  UploadVideoView.swift
//  Marauders
//

import PhotosUI
import SwiftUI

struct UploadVideoView: View {
    var onUploaded: () async -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var uploadFileURL: URL?
    @State private var isPreparing = false
    @State private var isUploading = false
    @State private var statusMessage: String?
    @State private var isSuccess = false

    private let client = VideoUploadAPIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("วิดีโอ") {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label(
                            uploadFileURL == nil ? "เลือกวิดีโอจากคลัง" : "เปลี่ยนวิดีโอ",
                            systemImage: "film"
                        )
                    }
                    .disabled(isUploading || isPreparing)

                    if isPreparing {
                        HStack {
                            ProgressView()
                            Text("กำลังแปลงเป็น MP4…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let uploadFileURL {
                        Text(uploadFileURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if pickerItem != nil {
                        HStack {
                            ProgressView()
                            Text("กำลังเตรียมไฟล์…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await upload() }
                    } label: {
                        if isUploading {
                            HStack {
                                ProgressView()
                                Text("กำลังอัปโหลด…")
                            }
                        } else {
                            Text("อัปโหลดไปฟีด")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canUpload)
                }

                if let statusMessage {
                    Section("สถานะ") {
                        CopyableStatusBanner(message: statusMessage, isSuccess: isSuccess)
                    }
                }
            }
            .navigationTitle("อัปโหลด")
            .onChange(of: pickerItem) { _, newItem in
                Task { await prepareVideo(from: newItem) }
            }
        }
    }

    private var canUpload: Bool {
        !isUploading && !isPreparing && uploadFileURL != nil
    }

    private func prepareVideo(from item: PhotosPickerItem?) async {
        guard let item else {
            uploadFileURL = nil
            return
        }
        uploadFileURL = nil
        statusMessage = nil
        isSuccess = false
        isPreparing = false
        AppLog.info("upload", "picker item selected — loading transferable")

        do {
            guard let video = try await item.loadTransferable(type: PickedVideoFile.self) else {
                statusMessage = "อ่านวิดีโอไม่ได้ — ลองคลิปสั้นกว่า"
                AppLog.error("upload", "loadTransferable returned nil")
                return
            }

            isPreparing = true
            defer { isPreparing = false }

            let mp4URL = try await VideoExportService.mp4URLForUpload(from: video.url)
            uploadFileURL = mp4URL
            AppLog.info("upload", "ready for upload mp4")
        } catch {
            uploadFileURL = nil
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "prepare failed: \(error.localizedDescription)")
        }
    }

    private func upload() async {
        guard let uploadFileURL else {
            AppLog.warning("upload", "upload tapped but no file")
            return
        }
        isUploading = true
        statusMessage = nil
        isSuccess = false
        defer { isUploading = false }

        AppLog.info("upload", "upload started")

        do {
            let item = try await client.upload(
                fileURL: uploadFileURL,
                mimeType: "video/mp4"
            )
            isSuccess = true
            statusMessage = "อัปโหลดสำเร็จ — กำลังเปิดฟีด"
            AppLog.info("upload", "upload OK videoId=\(item.id.uuidString)")
            pickerItem = nil
            self.uploadFileURL = nil
            await onUploaded()
            AppLog.info("upload", "feed reload requested after upload")
        } catch {
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "upload failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    UploadVideoView(onUploaded: {})
}
