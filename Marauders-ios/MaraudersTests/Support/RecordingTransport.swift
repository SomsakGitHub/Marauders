//
//  RecordingTransport.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// An `HTTPClient` that answers from a script and remembers what it was asked: every request, and the parts of every
/// upload. It answers either from a list (the next result for each request, in order; a request after the list ran out
/// fails) or from a closure that decides by the request, for tests where many requests are in flight at once.
///
/// nonisolated: Swift 6.4 would make a class that conforms to this MainActor-isolated protocol MainActor-isolated, but
/// requests arrive from the tasks of the code under test while the test reads what was recorded, which the lock makes
/// safe.
nonisolated final class RecordingTransport: HTTPClient, @unchecked Sendable {
    /// What an upload carried, in a form a test can compare: `HTTPMultipartPart` itself cannot be compared. A part that
    /// is copied from a file at send time (`fileAt`) is recorded by its URL, not by its bytes.
    enum RecordedPart: Equatable, Sendable {
        case field(name: String, value: String)
        case file(name: String, filename: String, mimeType: String, data: Data)
        case fileAt(name: String, filename: String, mimeType: String, url: URL)
    }

    /// What a request after the end of the list ends with.
    struct NothingScripted: Error {}

    typealias Responder = @Sendable (URLRequest) async throws -> HTTPClientResponse

    private let lock = NSLock()
    private var script: [Result<HTTPClientResponse, any Error>]
    private let responder: Responder?
    private let reportingProgress: [Double]
    private var seen: [URLRequest] = []
    private var seenUploads: [[RecordedPart]] = []

    /// - Parameter reportingProgress: What every upload tells its progress handler, in order, before it is answered.
    init(_ script: [Result<HTTPClientResponse, any Error>], reportingProgress: [Double] = []) {
        self.script = script
        self.responder = nil
        self.reportingProgress = reportingProgress
    }

    init(responder: @escaping Responder, reportingProgress: [Double] = []) {
        self.script = []
        self.responder = responder
        self.reportingProgress = reportingProgress
    }

    /// Every request that arrived, uploads included, in the order they arrived.
    var requests: [URLRequest] { lock.withLock { seen } }

    /// The parts of every upload, in order. A plain `data` request adds nothing here.
    var uploadedParts: [[RecordedPart]] { lock.withLock { seenUploads } }

    func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        lock.withLock { seen.append(request) }
        return try await answer(request)
    }

    func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        try await upload(request, multipart: multipart, progress: nil)
    }

    func upload(
        _ request: URLRequest, multipart: [HTTPMultipartPart], progress: UploadProgressHandler?
    ) async throws -> HTTPClientResponse {
        lock.withLock {
            seen.append(request)
            seenUploads.append(multipart.map(Self.recorded))
        }
        for fraction in reportingProgress { progress?(fraction) }
        return try await answer(request)
    }

    private func answer(_ request: URLRequest) async throws -> HTTPClientResponse {
        if let responder { return try await responder(request) }
        let next: Result<HTTPClientResponse, any Error>? = lock.withLock {
            script.isEmpty ? nil : script.removeFirst()
        }
        guard let next else { throw NothingScripted() }
        return try next.get()
    }

    private static func recorded(_ part: HTTPMultipartPart) -> RecordedPart {
        switch part {
        case .field(let name, let value):
            return .field(name: name, value: value)
        case .file(let name, let filename, let mimeType, let data):
            return .file(name: name, filename: filename, mimeType: mimeType, data: data)
        case .fileAt(let name, let filename, let mimeType, let url):
            return .fileAt(name: name, filename: filename, mimeType: mimeType, url: url)
        }
    }
}
