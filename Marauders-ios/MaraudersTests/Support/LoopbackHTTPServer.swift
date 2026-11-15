//
//  LoopbackHTTPServer.swift
//  MaraudersTests
//

import Foundation
import Network

/// A small HTTP server on 127.0.0.1, for the tests that need a real connection: `didSendBodyData` is never delivered
/// through a `URLProtocol` stub, so upload progress can only be seen over a socket.
///
/// It answers every request with one fixed status and body, and counts the body bytes each request carried.
nonisolated final class LoopbackHTTPServer: @unchecked Sendable {
    private let status: Int
    private let responseBody: Data
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var openConnections: [NWConnection] = []
    private var bodyByteCounts: [Int] = []

    init(status: Int = 201, body: Data = Data(#"{"ok":true}"#.utf8)) {
        self.status = status
        self.responseBody = body
    }

    /// How many body bytes each request carried, in the order the requests finished arriving.
    var receivedBodyByteCounts: [Int] { lock.withLock { bodyByteCounts } }

    /// Listens on a free port of 127.0.0.1 and returns `http://127.0.0.1:<port>/` once the port is ready.
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        lock.withLock { self.listener = listener }

        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                        once.run { continuation.resume(throwing: URLError(.badURL)) }
                        return
                    }
                    once.run { continuation.resume(returning: url) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let (listener, connections) = lock.withLock { (self.listener, openConnections) }
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    // MARK: - one request

    /// What has arrived of one request: the head until its blank line, then only a count of the body bytes.
    private struct Reading {
        var head = Data()
        var contentLength: Int?
        var bodyBytes = 0
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { openConnections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection, reading: Reading())
    }

    private func receive(on connection: NWConnection, reading: Reading) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var reading = reading
            if let data, !data.isEmpty { Self.absorb(data, into: &reading) }

            if let length = reading.contentLength, reading.bodyBytes >= length {
                answer(connection, bodyBytes: reading.bodyBytes)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, reading: reading)
            }
        }
    }

    /// Finds the end of the head, reads `Content-Length` from it, and from then on only counts bytes.
    private static func absorb(_ data: Data, into reading: inout Reading) {
        if reading.contentLength != nil {
            reading.bodyBytes += data.count
            return
        }
        reading.head.append(data)
        guard let end = reading.head.range(of: Data("\r\n\r\n".utf8)) else { return }

        let headers = String(decoding: reading.head[..<end.lowerBound], as: UTF8.self)
        let length = headers.split(separator: "\r\n").lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        reading.contentLength = length ?? 0
        reading.bodyBytes = reading.head.count - end.upperBound
        reading.head = Data()
    }

    private func answer(_ connection: NWConnection, bodyBytes: Int) {
        lock.withLock { bodyByteCounts.append(bodyBytes) }
        let head =
            "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(responseBody)
        connection.send(
            content: response, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Lets a continuation be resumed by whichever of several state changes comes first, and only once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ body: () -> Void) {
            let isFirst = lock.withLock {
                defer { done = true }
                return !done
            }
            if isFirst { body() }
        }
    }
}
