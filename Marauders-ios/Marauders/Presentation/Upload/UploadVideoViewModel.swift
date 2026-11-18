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
    /// An upload that ended without a clip, and whether Try again can work for it.
    struct FailedUpload: Equatable {
        let message: String
        let canRetry: Bool
    }

    var uploadFileURL: URL?
    var clipLocation: ClipLocation?
    var caption = ""
    var isPreparing = false
    var isCheckingAudio = false
    var audioAssessment: ClipAudioAssessment?
    var isResolvingClipLocation = false
    var statusMessage: String?
    var isSuccess = false

    var showClipLocationPrePrompt = false
    var showClipLocationDeniedAlert = false

    private let audioInspector: any ClipAudioInspecting
    private var preparationGeneration = 0
    private let prepareVideo: PrepareVideoForUploadUseCase
    private let uploads: ClipUploadUseCases
    private let videoLocationReader: VideoLocationReading
    /// Asks iOS for time to hand the clip to the uploader if the app leaves the screen meanwhile; answers how to give
    /// it back.
    private let holdAwake: @MainActor (String) -> @MainActor () -> Void
    private var pickerStagingURL: URL?
    /// Called with the clip the server stored, once, when the app is active and a viewer is signed in.
    var onUploaded: ((_ uploaded: FeedVideo) async -> Void)?

    private let locationManager: LocationManaging
    private let locationDelegateBridge = LocationManagerDelegateBridge()
    private var pendingClipLocationRequest = false

    /// Where the uploader says the upload stands: the screen shows this, and does no transfer of its own.
    private var snapshot = UploadSnapshot.idle
    /// The tap has handed the clip over and the uploader has not taken it on yet (it copies the clip first).
    private var isStagingUpload = false
    private var isAppActive = false
    /// Off until the root view says otherwise: a finished clip is never reported to nobody.
    private var isSignedIn = false
    /// The clip the feed was last told about, so a snapshot that repeats cannot report it twice.
    private var reportedFinishedID: UUID?
    private var finishedReport: Task<Void, Never>?

    init(
        prepareVideo: PrepareVideoForUploadUseCase,
        uploads: ClipUploadUseCases = ClipUploadUseCases(uploader: IdleClipUploader()),
        locationManager: LocationManaging = CLLocationManager(),
        videoLocationReader: VideoLocationReading = NoopVideoLocationReader(),
        audioInspector: any ClipAudioInspecting = NoopClipAudioInspector(),
        holdAwake: @escaping @MainActor (String) -> @MainActor () -> Void = BackgroundExecution.begin
    ) {
        self.audioInspector = audioInspector
        self.holdAwake = holdAwake
        self.prepareVideo = prepareVideo
        self.uploads = uploads
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

    /// The clip is being handed to the uploader, or is on its way to the Worker.
    var isUploading: Bool {
        switch snapshot {
        case .uploading, .finishing: true
        case .idle, .finished, .failed: isStagingUpload
        }
    }

    /// How much of the clip has been sent, from 0 to 1: 0 while it is handed over, 1 once every byte is sent. `nil` when
    /// nothing is uploading.
    var uploadProgress: Double? {
        switch snapshot {
        case .uploading(let fraction): fraction
        case .finishing: 1
        case .idle, .finished, .failed: isStagingUpload ? 0 : nil
        }
    }

    /// All the bytes are sent and the app waits for the Worker's answer.
    var isFinishingUpload: Bool { (uploadProgress ?? 0) >= 1 }

    /// "Uploading… 42%" (rounded down), "Finishing…" once all bytes are sent, `nil` when nothing is uploading. It never
    /// says 100%, because that would claim the clip is stored before the Worker has said so.
    var uploadProgressLabel: String? {
        guard let uploadProgress else { return nil }
        if uploadProgress >= 1 { return String(localized: "Finishing…") }
        return String(localized: "Uploading… \(Int((uploadProgress * 100).rounded(.down)))%")
    }

    /// The upload the uploader gave up on, while the viewer has not dealt with it.
    var failedUpload: FailedUpload? {
        guard case .failed(let message, let canRetry) = snapshot else { return nil }
        return FailedUpload(message: message, canRetry: canRetry)
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
        // A failed upload still holds its record and its copy of the clip: choosing a new video gives both up.
        if failedUpload != nil { await uploads.discard.execute() }
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
        // A second tap while one is under way would hand the same clip over twice.
        guard !isUploading else {
            AppLog.warning("upload", "upload requested while an upload is running")
            return
        }
        guard let uploadFileURL else {
            AppLog.warning("upload", "upload tapped but no file")
            return
        }
        guard let clipLocation else {
            statusMessage = String(localized: "Set the clip location before uploading")
            AppLog.warning("upload", "upload tapped but no clip location")
            return
        }

        // Covers the hand-over, which copies the clip into the app's own folder: released on every way out (handed over,
        // refused, cancelled). From then on the system carries the upload, and the app needs no hold.
        let release = holdAwake("Upload video")
        defer { release() }

        isStagingUpload = true
        defer { isStagingUpload = false }
        statusMessage = nil
        isSuccess = false

        AppLog.info("upload", "upload started")

        do {
            try await uploads.start.execute(
                ClipUploadRequest(
                    fileURL: uploadFileURL,
                    mimeType: "video/mp4",
                    clipLocation: clipLocation,
                    caption: caption,
                    audioAssessment: audioAssessment
                )
            )
        } catch {
            statusMessage = error.localizedDescription
            isSuccess = false
            AppLog.error("upload", "upload failed to start: \(error.localizedDescription)")
            return
        }
        // The button stays disabled until the uploader's first snapshot says where things stand.
        if case .idle = snapshot { snapshot = .uploading(fraction: 0) }
        discardExportStagingFile()
        audioAssessment = nil
        caption = ""
        AppLog.info("upload", "upload handed to the uploader")
    }

    /// Reads the uploader's snapshots for as long as the app lives. The root view runs it as a task of its own.
    func observeUploads() async {
        for await incoming in await uploads.observe.execute() {
            apply(incoming)
            await reportFinishedUploadIfNeeded()
        }
    }

    /// Whether the app is on screen. A clip that finished while it was not is reported once it is.
    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
        guard isActive, isSignedIn, case .finished = snapshot else { return }
        finishedReport = Task { [weak self] in await self?.reportFinishedUploadIfNeeded() }
    }

    /// Whether a viewer is signed in. A clip that finished while nobody was is reported once someone is: the sign in
    /// has by then deleted the upload of another account, so only the viewer's own clip is left to report.
    func setSignedIn(_ isSignedIn: Bool) {
        self.isSignedIn = isSignedIn
        guard isSignedIn, isAppActive, case .finished = snapshot else { return }
        finishedReport = Task { [weak self] in await self?.reportFinishedUploadIfNeeded() }
    }

    func retryUpload() async {
        AppLog.info("upload", "try again tapped")
        await uploads.retry.execute()
    }

    /// Gives the upload up, then clears the form for the next clip.
    func chooseAnotherVideo() async {
        AppLog.info("upload", "choose another video tapped")
        await uploads.discard.execute()
        resetPickedFile()
    }

    /// A fraction that is not a number is dropped, because min and max cannot clamp NaN and the label would trap on it.
    private func apply(_ incoming: UploadSnapshot) {
        switch incoming {
        case .idle:
            dropFailureMessage()
            snapshot = .idle
        case .finished:
            snapshot = incoming
        case .uploading(let fraction):
            guard !fraction.isNaN else { return }
            dropFailureMessage()
            snapshot = .uploading(fraction: min(max(fraction, 0), 1))
        case .finishing:
            dropFailureMessage()
            snapshot = .finishing
        case .failed(let message, let canRetry):
            snapshot = incoming
            statusMessage = message
            isSuccess = false
            AppLog.error("upload", "upload failed canRetry=\(canRetry)")
        }
    }

    /// A new attempt is under way, or the failed upload is gone (discarded): the message about it no longer applies.
    /// Only that message goes; a status line about something else stays.
    private func dropFailureMessage() {
        guard case .failed(let message, _) = snapshot, statusMessage == message else { return }
        statusMessage = nil
    }

    /// Tells the feed about a clip that finished, once, when the app is on screen and a viewer is signed in: never to
    /// nobody, and never to another account. The uploader's record is deleted first: a crash in between then costs only
    /// the move to the new clip, never a second report. While nobody is signed in the record stays on disk.
    private func reportFinishedUploadIfNeeded() async {
        guard isAppActive, isSignedIn, case .finished(let video) = snapshot, reportedFinishedID != video.id else {
            return
        }
        reportedFinishedID = video.id
        isSuccess = true
        statusMessage = String(localized: "Upload complete — opening feed")
        AppLog.info("upload", "upload OK videoId=\(video.id.uuidString)")
        await uploads.discard.execute()
        await onUploaded?(video)
        AppLog.info("upload", "feed reload requested after upload")
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
            self?.statusMessage = String(localized: "Couldn’t read location — try again")
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
            statusMessage = String(localized: "Couldn’t read location — try again")
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
