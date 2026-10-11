//
//  TestDoubles.swift
//  MaraudersTests
//

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

    init(result: Result<FeedVideo, Error>) {
        self.result = result
    }

    func upload(
        fileURL: URL,
        mimeType: String,
        clipLocation: ClipLocation
    ) async throws -> FeedVideo {
        uploadCount += 1
        uploadedFileURL = fileURL
        uploadedMimeType = mimeType
        uploadedClipLocation = clipLocation
        return try result.get()
    }
}

final class RecordingFeedRepository: FeedRepository, @unchecked Sendable {
    var result: Result<FeedPage, Error>
    private(set) var fetchCount = 0
    private(set) var lastLimit: Int?
    private(set) var lastCursor: UUID?

    init(result: Result<FeedPage, Error>) {
        self.result = result
    }

    func fetchFeed(limit: Int, cursor: UUID?) async throws -> FeedPage {
        fetchCount += 1
        lastLimit = limit
        lastCursor = cursor
        return try result.get()
    }
}

final class CallbackFlag: @unchecked Sendable {
    var wasCalled = false
}
