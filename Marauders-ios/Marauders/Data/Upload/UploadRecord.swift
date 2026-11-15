//
//  UploadRecord.swift
//  Marauders
//

import Foundation

/// One pending upload as it is kept on disk next to its staged body, so that it outlives the app: who it belongs to,
/// how the body was written, and where the upload stands. It holds nothing else: no token, caption, coordinates or
/// clip path.
nonisolated struct UploadRecord: Codable, Equatable, Sendable {
    /// The layout of the record file. The store does not read a file of any other version.
    static let currentVersion = 1

    var version: Int
    /// Names the record, its files and the key the Worker knows a repeat of the upload by.
    let id: UUID
    /// The `sub` of the access token the upload started with. Another account never sends it.
    let accountSubject: String
    /// The name of the body file in the store's directory.
    let bodyFileName: String
    /// The boundary the body was written with; the request that sends the body names the same one.
    let boundary: String
    /// The size of the body file in bytes.
    let byteCount: Int64
    let createdAt: Date
    var state: UploadRecordState

    /// What the viewer is told about this upload. Every byte sent is `finishing`, never a full bar: the Worker has not
    /// answered yet.
    var snapshot: UploadSnapshot {
        switch state {
        case .staged:
            .uploading(fraction: 0)
        case .uploading(let fraction, _):
            fraction < 1 ? .uploading(fraction: fraction) : .finishing
        case .finished(let video):
            .finished(video)
        case .failed(let failure):
            .failed(message: failure.message, canRetry: failure.canRetry)
        }
    }
}

/// Where a pending upload stands.
nonisolated enum UploadRecordState: Codable, Equatable, Sendable {
    /// The body is written and nothing is known to be sending it yet.
    case staged
    /// The body is on its way. `fraction` is the share sent; `refreshedOnce` says the access token was already traded
    /// for a new one after the Worker refused it, which the upload does only once.
    case uploading(fraction: Double, refreshedOnce: Bool)
    /// The Worker stored the clip. The record stays until the viewer has seen it.
    case finished(FeedVideo)
    /// The upload ended without a clip.
    case failed(UploadFailure)
}

/// Why an upload ended without a clip.
nonisolated enum UploadFailure: Codable, Equatable, Sendable {
    /// The access token was refused for good, and so was the one that replaced it.
    case sessionEnded
    /// The access token could not be replaced because the service could not be reached.
    case unavailable
    /// The transport failed; the text is its own.
    case connection(String)
    /// The Worker said to slow down (429).
    case rateLimited
    /// The Worker refused the upload and would refuse it again (4xx); the text is the Worker's `error`, else
    /// `Upload failed (status N)`.
    case rejected(String)
    /// The Worker failed (5xx); the text is the Worker's `error`, else `Upload failed (status N)`.
    case serverError(String)
    /// The system ended the upload, or the app lost track of it.
    case interrupted
    /// The upload went through but the answer never arrived, so the clip may exist.
    case responseLost
    /// The staged body is gone, and with it the clip.
    case bodyMissing

    /// What the viewer reads.
    var message: String {
        switch self {
        case .sessionEnded: "Your session ended. Sign in to try again."
        case .unavailable: "The service is unavailable right now. Try again."
        case .connection(let text), .rejected(let text), .serverError(let text): text
        case .rateLimited: "Too many uploads, try again in a minute"
        case .interrupted: "The upload was interrupted. Try again."
        case .responseLost: "The clip may have been uploaded, but the answer was lost. Try again."
        case .bodyMissing: "The clip is no longer on this iPhone. Choose the video again."
        }
    }

    /// Whether sending the clip again can work. It cannot when the Worker refused the upload, or when the clip is gone.
    var canRetry: Bool {
        switch self {
        case .rejected, .bodyMissing: false
        case .sessionEnded, .unavailable, .connection, .rateLimited, .serverError, .interrupted, .responseLost: true
        }
    }
}
