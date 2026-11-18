//
//  HTTPClient.swift
//  Marauders
//

import Foundation

/// Outcome of an HTTP request: the raw body plus the HTTP status code.
struct HTTPClientResponse: Sendable {
    let data: Data
    let statusCode: Int

    var isSuccess: Bool {
        (200...299).contains(statusCode)
    }
}

/// Transport-level error surfaced by the networking wrapper.
enum HTTPClientError: LocalizedError, Equatable {
    case invalidResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid server response")
        case .transport(let message):
            return message
        }
    }
}

/// Multipart part building block, decoupled from the transport so callers stay testable.
enum HTTPMultipartPart: Sendable {
    case field(name: String, value: String)
    case file(name: String, filename: String, mimeType: String, data: Data)
    /// A file that is copied into the body in chunks when the body is written, so it is never held whole in memory.
    case fileAt(name: String, filename: String, mimeType: String, url: URL)
}

/// Abstraction over the networking transport so API clients can be swapped in tests.
protocol HTTPClient: Sendable {
    func data(_ request: URLRequest) async throws -> HTTPClientResponse
    func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse
    /// Like `upload(_:multipart:)`, and tells `progress` how much of the body has been sent while it goes. `progress`
    /// is called on any thread.
    func upload(_ request: URLRequest, multipart: [HTTPMultipartPart], progress: UploadProgressHandler?) async throws
        -> HTTPClientResponse
}

extension HTTPClient {
    /// For a client that cannot tell how far an upload has got: it uploads and never calls `progress`.
    nonisolated func upload(
        _ request: URLRequest,
        multipart: [HTTPMultipartPart],
        progress: UploadProgressHandler?
    ) async throws -> HTTPClientResponse {
        try await upload(request, multipart: multipart)
    }
}

/// `HTTPClient` backed by `URLSession`.
///
/// A status outside 2xx is an answer, not an error, and a `URLError` (offline, timed out,
/// cancelled, ...) is rethrown as it is so callers can react to its code.
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let temporaryDirectory: URL

    /// - Parameters:
    ///   - session: Supplies the configuration: protocol classes, extra headers and timeouts.
    ///   - temporaryDirectory: Where a multipart body is staged on disk while it uploads.
    nonisolated init(
        session: URLSession = .shared,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.session = session
        self.temporaryDirectory = temporaryDirectory
    }

    nonisolated func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        do {
            let (data, response) = try await session.data(for: request)
            return try Self.makeResponse(data: data, response: response)
        } catch {
            throw Self.surfaced(error)
        }
    }

    nonisolated func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        try await upload(request, multipart: multipart, progress: nil)
    }

    nonisolated func upload(
        _ request: URLRequest,
        multipart: [HTTPMultipartPart],
        progress: UploadProgressHandler?
    ) async throws -> HTTPClientResponse {
        let boundary = "marauders.boundary.\(UUID().uuidString)"
        var request = request
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // The body goes through a file so a large clip streams from disk instead of being copied into
        // a second in-memory buffer. The file is removed on every path out, a failed write included.
        let bodyFile = temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        do {
            try await MultipartBodyWriter.write(multipart, boundary: boundary, to: bodyFile)
            // A new delegate for every transfer: it remembers the last percent it reported, and a replay after a 401
            // sends the body again from the start.
            let delegate = progress.map { UploadProgressDelegate(handler: $0) }
            let (data, response) = try await session.upload(for: request, fromFile: bodyFile, delegate: delegate)
            return try Self.makeResponse(data: data, response: response)
        } catch {
            throw Self.surfaced(error)
        }
    }
}

private extension URLSessionHTTPClient {
    nonisolated static func makeResponse(data: Data, response: URLResponse) throws -> HTTPClientResponse {
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        return HTTPClientResponse(data: data, statusCode: http.statusCode)
    }

    /// A `URLError`, a cancellation and this client's own errors pass through; anything else is a transport failure.
    nonisolated static func surfaced(_ error: Error) -> Error {
        switch error {
        case is URLError, is CancellationError, is HTTPClientError:
            return error
        default:
            return HTTPClientError.transport(error.localizedDescription)
        }
    }
}
