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
            return "Invalid server response"
        case .transport(let message):
            return message
        }
    }
}

/// Multipart part building block, decoupled from the transport so callers stay testable.
enum HTTPMultipartPart: Sendable {
    case field(name: String, value: String)
    case file(name: String, filename: String, mimeType: String, data: Data)
}

/// Abstraction over the networking transport so API clients can be swapped in tests.
protocol HTTPClient: Sendable {
    func data(_ request: URLRequest) async throws -> HTTPClientResponse
    func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse
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
        let boundary = "marauders.boundary.\(UUID().uuidString)"
        var request = request
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // The body goes through a file so a large clip streams from disk instead of being copied into
        // a second in-memory buffer. The file is removed on every path out, a failed write included.
        let bodyFile = temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        do {
            try await Self.writeMultipartBody(multipart, boundary: boundary, to: bodyFile)
            let (data, response) = try await session.upload(for: request, fromFile: bodyFile)
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

    /// Runs off the caller's actor: writing a clip of up to 100 MB is a long synchronous job.
    @concurrent
    static func writeMultipartBody(_ parts: [HTTPMultipartPart], boundary: String, to url: URL) async throws {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        for part in parts {
            switch part {
            case .field(let name, let value):
                let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escaped(name))\"\r\n\r\n"
                try handle.write(contentsOf: Data(head.utf8))
                try handle.write(contentsOf: Data(value.utf8))
            case .file(let name, let filename, let mimeType, let data):
                let head =
                    "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"\(escaped(name))\"; filename=\"\(escaped(filename))\"\r\n"
                    + "Content-Type: \(mimeType)\r\n\r\n"
                try handle.write(contentsOf: Data(head.utf8))
                try handle.write(contentsOf: data)
            }
            try handle.write(contentsOf: Data("\r\n".utf8))
        }
        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }

    /// Percent-encodes what would end a quoted header value early, the way a browser does for a form upload.
    /// Walks unicode scalars because "\r\n" is a single `Character` and would slip past a character match.
    nonisolated static func escaped(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result.append(contentsOf: "%22".unicodeScalars)
            case "\r": result.append(contentsOf: "%0D".unicodeScalars)
            case "\n": result.append(contentsOf: "%0A".unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result)
    }
}
