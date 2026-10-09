//
//  UploadVideoViewModel.swift
//  Marauders
//

import Foundation
import Observation

@MainActor
@Observable
final class UploadVideoViewModel {
    var uploadFileURL: URL?
    var isPreparing = false
    var isUploading = false
    var statusMessage: String?
    var isSuccess = false

    private let prepareVideo: PrepareVideoForUploadUseCase
    private let uploadVideo: UploadFeedVideoUseCase
    private var pickerStagingURL: URL?
    var onUploaded: (() async -> Void)?

    init(
        prepareVideo: PrepareVideoForUploadUseCase,
        uploadVideo: UploadFeedVideoUseCase
    ) {
        self.prepareVideo = prepareVideo
        self.uploadVideo = uploadVideo
    }

    var canUpload: Bool {
        !isUploading && !isPreparing && uploadFileURL != nil
    }

    func resetPickedFile() {
        discardAllStagingFiles()
        statusMessage = nil
        isSuccess = false
    }

    func prepare(sourceURL: URL) async {
        discardAllStagingFiles()
        pickerStagingURL = sourceURL
        statusMessage = nil
        isSuccess = false
        isPreparing = true
        defer { isPreparing = false }

        AppLog.info("upload", "prepare export from picker file")

        do {
            let mp4URL = try await prepareVideo.execute(sourceURL: sourceURL)
            TemporaryFileCleanup.deleteIfTemporary(pickerStagingURL)
            pickerStagingURL = nil
            uploadFileURL = mp4URL
            AppLog.info("upload", "ready for upload mp4")
        } catch {
            discardAllStagingFiles()
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "prepare failed: \(error.localizedDescription)")
        }
    }

    func upload() async {
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
            let item = try await uploadVideo.execute(fileURL: uploadFileURL)
            isSuccess = true
            statusMessage = "อัปโหลดสำเร็จ — กำลังเปิดฟีด"
            AppLog.info("upload", "upload OK videoId=\(item.id.uuidString)")
            discardExportStagingFile()
            await onUploaded?()
            AppLog.info("upload", "feed reload requested after upload")
        } catch {
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "upload failed: \(error.localizedDescription)")
        }
    }

    private func discardExportStagingFile() {
        TemporaryFileCleanup.deleteIfTemporary(uploadFileURL)
        uploadFileURL = nil
    }

    private func discardAllStagingFiles() {
        TemporaryFileCleanup.deleteIfTemporary(uploadFileURL)
        uploadFileURL = nil
        TemporaryFileCleanup.deleteIfTemporary(pickerStagingURL)
        pickerStagingURL = nil
    }
}
