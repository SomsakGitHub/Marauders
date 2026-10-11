//
//  StubURLProtocol.swift
//  MaraudersTests
//

import Foundation

/// Intercepts `URLSession` traffic in unit tests without hitting the network.
///
/// Handlers are keyed by a per-session token so that suites running in parallel
/// (Swift Testing runs suites concurrently) cannot clobber each other's stubs.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let sessionTokenHeader = "X-Stub-Session-Token"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func register(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> String {
        let token = UUID().uuidString
        lock.lock()
        handlers[token] = handler
        lock.unlock()
        return token
    }

    static func unregister(_ token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    static func handler(for token: String?) -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        guard let token else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handlers[token]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.sessionTokenHeader)
        guard let handler = Self.handler(for: token) else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "StubURLProtocol",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No handler registered"]
                )
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

enum StubURLSessionFactory {
    static func make(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let token = StubURLProtocol.register(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.sessionTokenHeader: token]
        return URLSession(configuration: configuration)
    }

    static func reset(_ session: URLSession) {
        guard let token = session.configuration.httpAdditionalHeaders?[StubURLProtocol.sessionTokenHeader] as? String else {
            return
        }
        StubURLProtocol.unregister(token)
    }

    static func httpResponse(
        for request: URLRequest,
        statusCode: Int,
        headerFields: [String: String]? = nil
    ) -> HTTPURLResponse {
        guard let url = request.url else {
            fatalError("URLRequest missing URL")
        }
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headerFields
        )!
    }
}
