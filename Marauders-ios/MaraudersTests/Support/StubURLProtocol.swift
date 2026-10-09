//
//  StubURLProtocol.swift
//  MaraudersTests
//

import Foundation

/// Intercepts `URLSession` traffic in unit tests without hitting the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
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
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        StubURLProtocol.handler = nil
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
