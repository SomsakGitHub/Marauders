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
    @State private var authorName = "@marauders"
    @State private var caption = ""
    @State private var musicTitle = "Original Sound — Marauders"
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

                Section("รายละเอียด") {
                    TextField("ชื่อผู้โพสต์ (@handle)", text: $authorName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("คำบรรยาย", text: $caption, axis: .vertical)
                        .lineLimit(2 ... 4)
                    TextField("ชื่อเพลง / เสียง", text: $musicTitle)
                }

                if !canUpload, !isUploading {
                    Section {
                        Text(uploadHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Section {
                        Text(statusMessage)
                            .foregroundStyle(isSuccess ? .green : .red)
                            .font(.subheadline)
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
        !isUploading && pickedVideo != nil && !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var uploadHint: String {
        if pickedVideo == nil {
            return "เลือกวิดีโอจากคลังก่อน"
        }
        if caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "กรอกคำบรรยายก่อนกดอัปโหลด"
        }
        return ""
    }

    private func loadPickedVideo(from item: PhotosPickerItem?) async {
        guard let item else {
            pickedVideo = nil
            return
        }
        pickedVideo = nil
        statusMessage = nil
        isSuccess = false

        do {
            guard let video = try await item.loadTransferable(type: PickedVideoFile.self) else {
                statusMessage = "อ่านวิดีโอไม่ได้ — ลองคลิปสั้นกว่า หรือบันทึกเป็น MP4"
                isSuccess = false
                return
            }
            pickedVideo = video
        } catch {
            pickedVideo = nil
            statusMessage = "เลือกวิดีโอไม่สำเร็จ: \(error.localizedDescription)"
            isSuccess = false
        }
    }

    private func upload() async {
        guard let pickedVideo else { return }
        isUploading = true
        statusMessage = nil
        isSuccess = false
        defer { isUploading = false }

        do {
            _ = try await client.upload(
                fileURL: pickedVideo.url,
                mimeType: pickedVideo.mimeType,
                authorName: authorName,
                caption: caption,
                musicTitle: musicTitle
            )
            isSuccess = true
            statusMessage = "อัปโหลดสำเร็จ — กำลังเปิดฟีด"
            caption = ""
            pickerItem = nil
            self.pickedVideo = nil
            await onUploaded()
        } catch {
            statusMessage = error.localizedDescription
            isSuccess = false
        }
    }
}

#Preview {
    UploadVideoView(onUploaded: {})
}
