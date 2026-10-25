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
    var onUploaded: (() async -> Void)?

    private let locationManager: LocationManaging
    private let locationDelegateBridge = LocationManagerDelegateBridge()
    private var pendingClipLocationRequest = false

    init(
        prepareVideo: PrepareVideoForUploadUseCase,
        uploadVideo: UploadFeedVideoUseCase,
        locationManager: LocationManaging = CLLocationManager(),
        videoLocationReader: VideoLocationReading = NoopVideoLocationReader(),
        audioInspector: any ClipAudioInspecting = FastClipAudioInspector()
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

    /// Whether the uploader named the language. Language detection no longer happens at upload:
    /// each viewer's iPhone works it out when they ask for AI audio, unless the uploader said.
    enum SpokenLanguageOrigin: Equatable {
        case chosen
        case unset
    }

    /// Language of the speech in the clip, as it will be sent with the upload.
    var spokenLanguageCode: String? { audioAssessment?.spokenLanguage?.knownCode }

    var spokenLanguageOrigin: SpokenLanguageOrigin {
        audioAssessment?.spokenLanguage?.status == "confirmed" ? .chosen : .unset
    }

    /// Music-only clips and clips without sound have no speech to label.
    var showsSpokenLanguagePicker: Bool {
        guard uploadFileURL != nil, !isPreparing, let assessment = audioAssessment else { return false }
        return assessment.content != .music && assessment.signal != .noTrack
    }

    /// The uploader names the language; `nil` goes back to Automatic, leaving viewers to detect it.
    func chooseSpokenLanguage(_ code: String?) {
        guard var assessment = audioAssessment else { return }
        if let code, !code.isEmpty {
            assessment.spokenLanguage = .chosen(code)
        } else {
            assessment.spokenLanguage = nil
        }
        audioAssessment = assessment
        AppLog.info("upload", "spoken language \(code == nil ? "left automatic" : "chosen") by uploader")
    }

    func resetPickedFile() {
        preparationGeneration += 1
        isPreparing = false
        isCheckingAudio = false
        audioAssessment = nil
        discardAllStagingFiles()
        clipLocation = AppRuntimeConfiguration.isUITesting
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
                if mp4URL != uploadFileURL && mp4URL != pickerStagingURL { TemporaryFileCleanup.deleteIfTemporary(mp4URL) }
                return
            }
            isCheckingAudio = true
            let audioCheckStarted = ProcessInfo.processInfo.systemUptime
            let result = await audioInspector.inspect(fileURL: mp4URL)
            guard current == preparationGeneration, !Task.isCancelled else {
                if mp4URL != uploadFileURL && mp4URL != pickerStagingURL { TemporaryFileCleanup.deleteIfTemporary(mp4URL) }
                return
            }
            if sourceURL != mp4URL { TemporaryFileCleanup.deleteIfTemporary(sourceURL) }
            pickerStagingURL = nil
            uploadFileURL = mp4URL
            audioAssessment = result
            #if DEBUG
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - audioCheckStarted) * 1000)
            let report = "content=\(result.content.rawValue) speech=\(result.speechConfidence) music=\(result.musicConfidence) signal=\(result.signal) languageHint=\(result.languageHint ?? "unknown") sampledSeconds=\(String(format: "%.2f", result.sampledSeconds)) elapsedMs=\(elapsed) exceedsTranslationLimit=\(result.exceedsTranslationLimit)"
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
        statusMessage = nil
        isSuccess = false
        defer { isUploading = false }

        AppLog.info("upload", "upload started")

        do {
            let item = try await uploadVideo.execute(
                fileURL: uploadFileURL,
                clipLocation: clipLocation,
                caption: caption,
                audioAssessment: audioAssessment
            )
            isSuccess = true
            statusMessage = "Upload complete — opening feed"
            AppLog.info("upload", "upload OK videoId=\(item.id.uuidString)")
            #if DEBUG
            if let audioAssessment {
                AppLog.info("upload.audio-check", "videoId=\(item.id.uuidString) signal=\(audioAssessment.signal) languageHint=\(audioAssessment.languageHint ?? "unknown")")
            }
            #endif
            discardExportStagingFile()
            audioAssessment = nil
            caption = ""
            await onUploaded?()
            AppLog.info("upload", "feed reload requested after upload")
        } catch {
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "upload failed: \(error.localizedDescription)")
        }
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
