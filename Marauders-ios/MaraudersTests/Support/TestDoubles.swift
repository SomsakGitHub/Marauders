//
//  TestDoubles.swift
//  MaraudersTests
//

import CoreLocation
import Foundation

@testable import Marauders

extension SpokenLanguageAssessment {
    /// A clip whose uploader named the language, as older builds of the app let them do.
    static func chosen(_ code: String) -> Self {
        .init(status: "confirmed", code: code.lowercased(), method: "uploader")
    }
}

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
    var uploadedID: UUID?
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

final class StubCommentRepository: CommentRepository, @unchecked Sendable {
    /// One result per call, in order; the last one repeats when the queue runs out.
    var fetchResults: [Result<CommentPage, Error>]
    var postResult: Result<Comment, Error>?
    var deleteResult: Result<Void, Error> = .success(())
    /// Runs before a fetch returns, so a test can interleave another action with it.
    var beforeFetchReturns: (@Sendable () async -> Void)?
    /// The same for a post and a delete: the request is still in flight while the hook runs.
    var beforePostReturns: (@Sendable () async -> Void)?
    var beforeDeleteReturns: (@Sendable () async -> Void)?
    private(set) var fetches: [(videoID: UUID, cursor: UUID?, limit: Int)] = []
    private(set) var posts: [(videoID: UUID, body: String, language: String?)] = []
    private(set) var deletes: [(videoID: UUID, commentID: UUID)] = []

    init(fetchResults: [Result<CommentPage, Error>] = [.success(CommentPage(items: [], nextCursor: nil))]) {
        self.fetchResults = fetchResults
    }

    func fetchComments(videoID: UUID, cursor: UUID?, limit: Int) async throws -> CommentPage {
        let index = min(fetches.count, fetchResults.count - 1)
        fetches.append((videoID, cursor, limit))
        let result = fetchResults[index]
        await beforeFetchReturns?()
        return try result.get()
    }

    func postComment(videoID: UUID, body: String, language: String?) async throws -> Comment {
        posts.append((videoID, body, language))
        await beforePostReturns?()
        if let postResult {
            return try postResult.get()
        }
        return Comment(body: body, language: language, authorName: "@me", canDelete: true)
    }

    func deleteComment(videoID: UUID, commentID: UUID) async throws {
        deletes.append((videoID, commentID))
        await beforeDeleteReturns?()
        try deleteResult.get()
    }
}

final class StubClipLikeRepository: ClipLikeRepository, @unchecked Sendable {
    /// One result per call, in order; the last one repeats when the queue runs out.
    var results: [Result<ClipLikeState, Error>]
    /// Runs before a call returns, with the number of calls made so far: the request is still in flight while it runs.
    var beforeReturn: (@Sendable (Int) async -> Void)?
    private(set) var calls: [(liked: Bool, videoID: UUID)] = []
    /// The most requests that were out at the same moment.
    private(set) var peakConcurrency = 0
    private var outNow = 0

    init(results: [Result<ClipLikeState, Error>] = [.success(ClipLikeState(liked: true, count: 1))]) {
        self.results = results
    }

    func setLiked(_ liked: Bool, videoID: UUID) async throws -> ClipLikeState {
        let index = min(calls.count, results.count - 1)
        calls.append((liked, videoID))
        outNow += 1
        peakConcurrency = max(peakConcurrency, outNow)
        defer { outNow -= 1 }
        await beforeReturn?(calls.count)
        return try results[index].get()
    }
}

final class StubUserFollowRepository: UserFollowRepository, @unchecked Sendable {
    /// One result per call, in order; the last one repeats when the queue runs out.
    var results: [Result<UserFollowChange, Error>]
    /// Runs before a call returns, with the number of calls made so far: the request is still in flight while it runs.
    var beforeReturn: (@Sendable (Int) async -> Void)?
    private(set) var calls: [(following: Bool, handle: String)] = []
    /// The most requests that were out at the same moment.
    private(set) var peakConcurrency = 0
    private var outNow = 0

    init(
        results: [Result<UserFollowChange, Error>] = [
            .success(UserFollowChange(following: true, followerCount: 1, viewerFollowingCount: 1))
        ]
    ) {
        self.results = results
    }

    func setFollowing(_ following: Bool, handle: String) async throws -> UserFollowChange {
        let index = min(calls.count, results.count - 1)
        calls.append((following, handle))
        outNow += 1
        peakConcurrency = max(peakConcurrency, outNow)
        defer { outNow -= 1 }
        await beforeReturn?(calls.count)
        return try results[index].get()
    }
}

final class StubFollowListRepository: FollowListRepository, @unchecked Sendable {
    /// One result per call, in order; the last one repeats when the queue runs out.
    var fetchResults: [Result<FollowListPage, Error>]
    /// Runs with the number of calls made so far while the request is "in flight", so a test can interleave another action.
    var beforeFetchReturns: (@Sendable (Int) async -> Void)?
    private(set) var fetches: [(handle: String, kind: FollowListKind, cursor: String?, limit: Int)] = []

    init(fetchResults: [Result<FollowListPage, Error>] = [.success(FollowListPage(entries: [], nextCursor: nil))]) {
        self.fetchResults = fetchResults
    }

    func fetchList(handle: String, kind: FollowListKind, cursor: String?, limit: Int) async throws -> FollowListPage {
        let index = min(fetches.count, fetchResults.count - 1)
        fetches.append((handle, kind, cursor, limit))
        await beforeFetchReturns?(fetches.count)
        return try fetchResults[index].get()
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
    /// What a report sent while closed answers about the viewer's sharing.
    var sharesLocation: Bool? = true
    private(set) var reportedLocations: [ClipLocation] = []
    private(set) var whileClosedCount = 0

    var reportCount: Int { reportedLocations.count }
    var lastReported: ClipLocation? { reportedLocations.last }

    init(result: Result<Void, Error> = .success(())) {
        self.result = result
    }

    func report(location: ClipLocation) async throws {
        reportedLocations.append(location)
        try result.get()
    }

    func reportWhileClosed(location: ClipLocation) async throws -> Bool? {
        reportedLocations.append(location)
        whileClosedCount += 1
        try result.get()
        return sharesLocation
    }
}

@MainActor
final class FakeLocationManager: @MainActor BackgroundLocationManaging {
    var authorizationStatus: CLAuthorizationStatus
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters
    var delegate: CLLocationManagerDelegate?
    private(set) var authorizationRequestCount = 0
    private(set) var alwaysAuthorizationRequestCount = 0
    private(set) var locationRequestCount = 0
    private(set) var significantChangeStarts = 0
    private(set) var significantChangeStops = 0
    private(set) var visitStarts = 0
    private(set) var visitStops = 0

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

    func startMonitoringSignificantLocationChanges() {
        significantChangeStarts += 1
    }

    func stopMonitoringSignificantLocationChanges() {
        significantChangeStops += 1
    }

    func startMonitoringVisits() {
        visitStarts += 1
    }

    func stopMonitoringVisits() {
        visitStops += 1
    }

    func simulateVisit(_ visit: CLVisit) {
        delegate?.locationManager?(CLLocationManager(), didVisit: visit)
    }
}
