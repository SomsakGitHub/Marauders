//
//  UploadVideoViewModel.swift
//  Marauders
//

import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class UploadVideoViewModel {
    var uploadFileURL: URL?
    var clipLocation: ClipLocation?
    var caption = ""
    var isPreparing = false
    var isCheckingAudio = false
    var audioAssessment: ClipAudioAssessment?
    var isUploading = false
    /// How much of the clip's body has been sent, from 0 to 1, while it uploads. `nil` when nothing is uploading.
    private(set) var uploadProgress: Double?
    var isResolvingClipLocation = false
    var statusMessage: String?
    var isSuccess = false

    var showClipLocationPrePrompt = false
    var showClipLocationDeniedAlert = false

    private let audioInspector: any ClipAudioInspecting
    private var preparationGeneration = 0
    private let prepareVideo: PrepareVideoForUploadUseCase
    private let uploadVideo: UploadFeedVideoUseCase
    private let videoLocationReader: VideoLocationReading
    private var pickerStagingURL: URL?
    /// Called with the clip the server stored, once the upload succeeded.
    var onUploaded: ((_ uploaded: FeedVideo) async -> Void)?

    private let locationManager: LocationManaging
    private let locationDelegateBridge = LocationManagerDelegateBridge()
    private var pendingClipLocationRequest = false
    /// Counts uploads, so a report from an upload that has ended cannot move the bar of the next one.
    private var uploadAttempt = 0

    init(
        prepareVideo: PrepareVideoForUploadUseCase,
        uploadVideo: UploadFeedVideoUseCase,
        locationManager: LocationManaging = CLLocationManager(),
        videoLocationReader: VideoLocationReading = NoopVideoLocationReader(),
        audioInspector: any ClipAudioInspecting = NoopClipAudioInspector()
    ) {
        self.audioInspector = audioInspector
        self.prepareVideo = prepareVideo
        self.uploadVideo = uploadVideo
        self.locationManager = locationManager
        self.videoLocationReader = videoLocationReader

        if AppRuntimeConfiguration.isUITesting {
            clipLocation = ClipLocation(latitude: 13.7563, longitude: 100.5018)
        }

        configureLocationManagerIfNeeded()
    }

    var canUpload: Bool {
        !isUploading
            && !isPreparing
            && !isResolvingClipLocation
            && uploadFileURL != nil
            && clipLocation != nil
    }

    /// All the bytes are sent and the app waits for the Worker's answer.
    var isFinishingUpload: Bool { isUploading && (uploadProgress ?? 0) >= 1 }

    /// "Uploading… 42%" (rounded down), "Finishing…" once all bytes are sent, `nil` when nothing is uploading. It never
    /// says 100%, because that would claim the clip is stored before the Worker has said so.
    var uploadProgressLabel: String? {
        guard let uploadProgress else { return nil }
        if uploadProgress >= 1 { return "Finishing…" }
        return "Uploading… \(Int((uploadProgress * 100).rounded(.down)))%"
    }

    func resetPickedFile() {
        preparationGeneration += 1
        isPreparing = false
        isCheckingAudio = false
        audioAssessment = nil
        discardAllStagingFiles()
        clipLocation =
            AppRuntimeConfiguration.isUITesting
            ? ClipLocation(latitude: 13.7563, longitude: 100.5018)
            : nil
        caption = ""
        statusMessage = nil
        isSuccess = false
    }

    func prepare(sourceURL: URL) async {
        preparationGeneration += 1
        let current = preparationGeneration
        discardAllStagingFiles()
        pickerStagingURL = sourceURL
        audioAssessment = nil
        statusMessage = nil
        isSuccess = false
        isPreparing = true
        isCheckingAudio = false
        defer { if current == preparationGeneration { isPreparing = false; isCheckingAudio = false } }
        AppLog.info("upload", "prepare export from picker file")
        let suggestedLocation = await videoLocationReader.location(fromVideoAt: sourceURL)
        guard current == preparationGeneration, !Task.isCancelled else { return }
        if let suggestedLocation { clipLocation = suggestedLocation }
        do {
            let mp4URL = try await prepareVideo.execute(sourceURL: sourceURL)
            guard current == preparationGeneration, !Task.isCancelled else {
                if mp4URL != uploadFileURL && mp4URL != pickerStagingURL {
                    TemporaryFileCleanup.deleteIfTemporary(mp4URL)
                }
                return
            }
            isCheckingAudio = true
            let audioCheckStarted = ProcessInfo.processInfo.systemUptime
            let result = await audioInspector.inspect(fileURL: mp4URL)
            guard current == preparationGeneration, !Task.isCancelled else {
                if mp4URL != uploadFileURL && mp4URL != pickerStagingURL {
                    TemporaryFileCleanup.deleteIfTemporary(mp4URL)
                }
                return
            }
            if sourceURL != mp4URL { TemporaryFileCleanup.deleteIfTemporary(sourceURL) }
            pickerStagingURL = nil
            uploadFileURL = mp4URL
            audioAssessment = result
            #if DEBUG
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - audioCheckStarted) * 1000)
                let report =
                    "content=\(result.content.rawValue) speech=\(result.speechConfidence) music=\(result.musicConfidence) signal=\(result.signal) languageHint=\(result.languageHint ?? "unknown") sampledSeconds=\(String(format: "%.2f", result.sampledSeconds)) elapsedMs=\(elapsed) exceedsTranslationLimit=\(result.exceedsTranslationLimit)"
                AppLog.info("upload.audio-check", report)
                print("[upload.audio-check] \(report)")
            #endif
            AppLog.info("upload", "ready for upload; quick audio check completed")
        } catch {
            guard current == preparationGeneration else { return }
            discardAllStagingFiles()
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "prepare failed: \(error.localizedDescription)")
        }
    }

    func applyClipLocation(_ location: ClipLocation) {
        clipLocation = location
        statusMessage = nil
        AppLog.info("upload", "clip location chosen manually")
    }

    func setClipLocationFromCurrentPositionTapped() {
        if AppRuntimeConfiguration.isUITesting {
            clipLocation = ClipLocation(latitude: 13.7563, longitude: 100.5018)
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            showClipLocationPrePrompt = true
        case .authorizedAlways, .authorizedWhenInUse:
            requestClipLocationFix()
        case .denied, .restricted:
            showClipLocationDeniedAlert = true
        @unknown default:
            break
        }
    }

    func confirmClipLocationPermissionRequest() {
        showClipLocationPrePrompt = false
        pendingClipLocationRequest = true
        locationManager.requestWhenInUseAuthorization()
    }

    func cancelClipLocationPermissionRequest() {
        showClipLocationPrePrompt = false
        pendingClipLocationRequest = false
    }

    func upload() async {
        guard let uploadFileURL else {
            AppLog.warning("upload", "upload tapped but no file")
            return
        }
        guard let clipLocation else {
            statusMessage = "Set the clip location before uploading"
            AppLog.warning("upload", "upload tapped but no clip location")
            return
        }

        isUploading = true
        uploadProgress = 0
        uploadAttempt += 1
        let attempt = uploadAttempt
        statusMessage = nil
        isSuccess = false
        defer {
            isUploading = false
            uploadProgress = nil
        }

        AppLog.info("upload", "upload started")

        do {
            let item = try await uploadVideo.execute(
                fileURL: uploadFileURL,
                clipLocation: clipLocation,
                caption: caption,
                audioAssessment: audioAssessment,
                progress: { [weak self] fraction in
                    Task { @MainActor in self?.applyUploadProgress(fraction, attempt: attempt) }
                }
            )
            isSuccess = true
            statusMessage = "Upload complete — opening feed"
            AppLog.info("upload", "upload OK videoId=\(item.id.uuidString)")
            #if DEBUG
                if let audioAssessment {
                    AppLog.info(
                        "upload.audio-check",
                        "videoId=\(item.id.uuidString) signal=\(audioAssessment.signal) languageHint=\(audioAssessment.languageHint ?? "unknown")"
                    )
                }
            #endif
            discardExportStagingFile()
            audioAssessment = nil
            caption = ""
            await onUploaded?(item)
            AppLog.info("upload", "feed reload requested after upload")
        } catch {
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "upload failed: \(error.localizedDescription)")
        }
    }

    /// Called from the transfer's thread through a hop to the main actor, so it can arrive after the upload ended or
    /// after the next one began: only the upload that is running may move the bar.
    private func applyUploadProgress(_ fraction: Double, attempt: Int) {
        guard isUploading, attempt == uploadAttempt else { return }
        uploadProgress = min(max(fraction, 0), 1)
    }

    private func configureLocationManagerIfNeeded() {
        guard !AppRuntimeConfiguration.isUITesting else { return }

        locationDelegateBridge.onAuthorizationChange = { [weak self] in
            self?.handleAuthorizationChange()
        }
        locationDelegateBridge.onLocations = { [weak self] locations in
            self?.handleLocations(locations)
        }
        locationDelegateBridge.onFailure = { [weak self] error in
            self?.isResolvingClipLocation = false
            self?.statusMessage = "Couldn’t read location — try again"
            AppLog.warning("upload", "clip location failed: \(error.localizedDescription)")
        }

        locationManager.delegate = locationDelegateBridge
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func handleAuthorizationChange() {
        guard pendingClipLocationRequest else { return }

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            pendingClipLocationRequest = false
            requestClipLocationFix()
        case .denied, .restricted:
            pendingClipLocationRequest = false
            showClipLocationDeniedAlert = true
        case .notDetermined:
            break
        @unknown default:
            pendingClipLocationRequest = false
        }
    }

    private func requestClipLocationFix() {
        isResolvingClipLocation = true
        locationManager.requestLocation()
    }

    private func handleLocations(_ locations: [CLLocation]) {
        isResolvingClipLocation = false
        guard let coordinate = locations.last?.coordinate,
            let location = ClipLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        else {
            statusMessage = "Couldn’t read location — try again"
            return
        }
        clipLocation = location
        statusMessage = nil
        AppLog.info("upload", "clip location set")
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
