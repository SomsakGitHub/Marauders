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
    var isPreparing = false
    var isUploading = false
    var isResolvingClipLocation = false
    var statusMessage: String?
    var isSuccess = false

    var showClipLocationPrePrompt = false
    var showClipLocationDeniedAlert = false

    private let prepareVideo: PrepareVideoForUploadUseCase
    private let uploadVideo: UploadFeedVideoUseCase
    private var pickerStagingURL: URL?
    var onUploaded: (() async -> Void)?

    private let locationManager: CLLocationManager
    private let locationDelegateBridge = LocationManagerDelegateBridge()
    private var pendingClipLocationRequest = false

    init(
        prepareVideo: PrepareVideoForUploadUseCase,
        uploadVideo: UploadFeedVideoUseCase,
        locationManager: CLLocationManager = CLLocationManager()
    ) {
        self.prepareVideo = prepareVideo
        self.uploadVideo = uploadVideo
        self.locationManager = locationManager

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

    func resetPickedFile() {
        discardAllStagingFiles()
        clipLocation = AppRuntimeConfiguration.isUITesting
            ? ClipLocation(latitude: 13.7563, longitude: 100.5018)
            : nil
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
            let item = try await uploadVideo.execute(fileURL: uploadFileURL, clipLocation: clipLocation)
            isSuccess = true
            statusMessage = "Upload complete — opening feed"
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

    private func configureLocationManagerIfNeeded() {
        guard !AppRuntimeConfiguration.isUITesting else { return }

        locationDelegateBridge.onAuthorizationChange = { [weak self] manager in
            Task { @MainActor in
                self?.handleAuthorizationChange(manager)
            }
        }
        locationDelegateBridge.onLocations = { [weak self] locations in
            Task { @MainActor in
                self?.handleLocations(locations)
            }
        }
        locationDelegateBridge.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.isResolvingClipLocation = false
                self?.statusMessage = "Couldn’t read location — try again"
                AppLog.warning("upload", "clip location failed: \(error.localizedDescription)")
            }
        }

        locationManager.delegate = locationDelegateBridge
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func handleAuthorizationChange(_ manager: CLLocationManager) {
        guard pendingClipLocationRequest else { return }

        switch manager.authorizationStatus {
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
