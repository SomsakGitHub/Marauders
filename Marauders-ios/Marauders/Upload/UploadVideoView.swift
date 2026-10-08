//
//  UploadVideoView.swift
//  Marauders
//

import PhotosUI
import SwiftUI

struct UploadVideoView: View {
    var onUploaded: () async -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedVideo: PickedVideoFile?
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
                            pickedVideo == nil ? "เลือกวิดีโอจากคลัง" : "เปลี่ยนวิดีโอ",
                            systemImage: "film"
                        )
                    }
                    .disabled(isUploading)

                    if let pickedVideo {
                        Text(pickedVideo.url.lastPathComponent)
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
                Task { await loadPickedVideo(from: newItem) }
            }
        }
    }

    private var canUpload: Bool {
        !isUploading && pickedVideo != nil
    }

    private func loadPickedVideo(from item: PhotosPickerItem?) async {
        guard let item else {
            pickedVideo = nil
            return
        }
        pickedVideo = nil
        statusMessage = nil
        isSuccess = false
        AppLog.info("upload", "picker item selected — loading transferable")

        do {
            guard let video = try await item.loadTransferable(type: PickedVideoFile.self) else {
                let msg = "อ่านวิดีโอไม่ได้ — ลองคลิปสั้นกว่า หรือบันทึกเป็น MP4"
                statusMessage = msg
                isSuccess = false
                AppLog.error("upload", "loadTransferable returned nil")
                return
            }
            pickedVideo = video
            let size = (try? FileManager.default.attributesOfItem(atPath: video.url.path)[.size] as? NSNumber)?
                .int64Value ?? -1
            AppLog.info("upload", "video ready ext=\(video.url.pathExtension) mime=\(video.mimeType) bytes=\(size)")
        } catch {
            pickedVideo = nil
            statusMessage = "เลือกวิดีโอไม่สำเร็จ: \(error.localizedDescription)"
            isSuccess = false
            AppLog.error("upload", "loadTransferable failed: \(error.localizedDescription)")
        }
    }

    private func upload() async {
        guard let pickedVideo else {
            AppLog.warning("upload", "upload tapped but no picked file")
            return
        }
        isUploading = true
        statusMessage = nil
        isSuccess = false
        defer { isUploading = false }

        AppLog.info("upload", "upload started")

        do {
            let item = try await client.upload(
                fileURL: pickedVideo.url,
                mimeType: pickedVideo.mimeType
            )
            isSuccess = true
            statusMessage = "อัปโหลดสำเร็จ — กำลังเปิดฟีด"
            AppLog.info("upload", "upload OK videoId=\(item.id.uuidString)")
            pickerItem = nil
            self.pickedVideo = nil
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
