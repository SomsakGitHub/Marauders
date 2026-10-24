//
//  TestDoubles.swift
//  MaraudersTests
//

import CoreLocation
import Foundation
@testable import Marauders

enum StubError: Error, Equatable {
    case exportFailed
    case uploadFailed
    case feedFailed
}

extension StubError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .exportFailed: return "export failed"
        case .uploadFailed: return "upload failed"
        case .feedFailed: return "feed failed"
        }
    }
}

struct StubVideoExporter: VideoExporting {
    let result: Result<URL, Error>

    func mp4URLForUpload(from sourceURL: URL) async throws -> URL {
        try result.get()
    }
}

struct StubVideoLocationReader: VideoLocationReading {
    let location: ClipLocation?

    func location(fromVideoAt url: URL) async -> ClipLocation? { location }
}

final class RecordingVideoExporter: VideoExporting, @unchecked Sendable {
    var result: Result<URL, Error>
    private(set) var lastSourceURL: URL?

    init(result: Result<URL, Error>) {
        self.result = result
    }

    func mp4URLForUpload(from sourceURL: URL) async throws -> URL {
        lastSourceURL = sourceURL
        return try result.get()
    }
}

final class RecordingVideoUploadRepository: VideoUploadRepository, @unchecked Sendable {
    var result: Result<FeedVideo, Error>
    private(set) var uploadCount = 0
    private(set) var uploadedFileURL: URL?
    private(set) var uploadedMimeType: String?
    private(set) var uploadedClipLocation: ClipLocation?
    private(set) var uploadedCaption: String?

    init(result: Result<FeedVideo, Error>) {
        self.result = result
    }

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation,
        caption: String
    ) async throws -> FeedVideo {
        uploadCount += 1
        uploadedFileURL = fileURL
        uploadedMimeType = mimeType
        uploadedClipLocation = clipLocation
        uploadedCaption = caption
        return try result.get()
    }
}

final class RecordingFeedRepository: FeedRepository, @unchecked Sendable {
    var result: Result<FeedPage, Error>
    var resultForCountry: [String: Result<FeedPage, Error>] = [:]
    private(set) var fetchCount = 0
    private(set) var lastLimit: Int?
    private(set) var lastCursor: UUID?
    private(set) var lastCountry: String?

    init(result: Result<FeedPage, Error>) {
        self.result = result
    }

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        try await fetchFeed(limit: limit, cursor: cursor, country: nil)
    }

    func fetchFeed(limit: Int, cursor: UUID?, country: String?) async throws -> FeedPage {
        fetchCount += 1
        lastLimit = limit
        lastCursor = cursor
        lastCountry = country
        if let country, let scoped = resultForCountry[country] {
            return try scoped.get()
        }
        return try result.get()
    }
}

final class CallbackFlag: @unchecked Sendable {
    var wasCalled = false
}

final class StubUserProfileRepository: UserProfileRepository, @unchecked Sendable {
    var result: Result<UserProfile, Error>
    var deleteResult: Result<Void, Error> = .success(())
    var publicResult: Result<PublicUserProfile, Error>?
    var updateHandleResult: Result<String, Error>?
    var updateAvatarResult: Result<URL, Error>?
    private(set) var fetchCount = 0
    private(set) var deletedIDs: [UUID] = []
    private(set) var requestedHandles: [String] = []
    private(set) var updatedHandles: [String] = []
    private(set) var updatedAvatars: [(imageData: Data, mimeType: String)] = []

    init(result: Result<UserProfile, Error>) {
        self.result = result
    }

    func fetchProfile() async throws -> UserProfile {
        fetchCount += 1
        return try result.get()
    }

    func fetchPublicProfile(handle: String) async throws -> PublicUserProfile {
        requestedHandles.append(handle)
        if let publicResult {
            return try publicResult.get()
        }
        return PublicUserProfile(handle: handle)
    }

    func updateHandle(_ handle: String) async throws -> String {
        updatedHandles.append(handle)
        if let updateHandleResult {
            return try updateHandleResult.get()
        }
        return handle
    }

    func updateAvatar(imageData: Data, mimeType: String) async throws -> URL {
        updatedAvatars.append((imageData, mimeType))
        if let updateAvatarResult {
            return try updateAvatarResult.get()
        }
        return URL(string: "https://example.com/avatar.jpg")!
    }

    func deleteClip(id: UUID) async throws {
        deletedIDs.append(id)
        try deleteResult.get()
    }
}

final class StubAvatarImagePreparer: AvatarImagePreparing, @unchecked Sendable {
    var result: Data?

    init(result: Data? = Data([0xFF, 0xD8, 0xFF])) {
        self.result = result
    }

    func prepareJPEG(from data: Data, maxDimension: CGFloat) -> Data? {
        result
    }
}

final class RecordingUserLocationRepository: UserLocationRepository, @unchecked Sendable {
    var result: Result<Void, Error>
    private(set) var reportedLocations: [ClipLocation] = []

    var reportCount: Int { reportedLocations.count }
    var lastReported: ClipLocation? { reportedLocations.last }

    init(result: Result<Void, Error> = .success(())) {
        self.result = result
    }

    func report(location: ClipLocation) async throws {
        reportedLocations.append(location)
        try result.get()
    }
}

@MainActor
final class FakeLocationManager: LocationManaging {
    var authorizationStatus: CLAuthorizationStatus
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters
    var delegate: CLLocationManagerDelegate?
    private(set) var authorizationRequestCount = 0
    private(set) var alwaysAuthorizationRequestCount = 0
    private(set) var locationRequestCount = 0

    init(authorizationStatus: CLAuthorizationStatus = .notDetermined) {
        self.authorizationStatus = authorizationStatus
    }

    func requestAlwaysAuthorization() {
        alwaysAuthorizationRequestCount += 1
    }

    func requestWhenInUseAuthorization() {
        authorizationRequestCount += 1
    }

    func requestLocation() {
        locationRequestCount += 1
    }

    func simulateAuthorizationChange() {
        delegate?.locationManagerDidChangeAuthorization?(CLLocationManager())
    }

    func simulateLocations(_ locations: [CLLocation]) {
        delegate?.locationManager?(CLLocationManager(), didUpdateLocations: locations)
    }
}
