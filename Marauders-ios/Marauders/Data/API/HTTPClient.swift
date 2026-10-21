//
//  HTTPClient.swift
//  Marauders
//

import Alamofire
import Foundation

/// Outcome of an HTTP request: the raw body plus the HTTP status code.
struct HTTPClientResponse: Sendable {
    let data: Data
    let statusCode: Int

    var isSuccess: Bool {
        (200 ... 299).contains(statusCode)
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

/// Multipart part building block, decoupled from Alamofire so callers stay testable.
enum HTTPMultipartPart: Sendable {
    case field(name: String, value: String)
    case file(name: String, filename: String, mimeType: String, data: Data)
}

/// Abstraction over the networking transport so API clients can be swapped in tests.
protocol HTTPClient: Sendable {
    func data(_ request: URLRequest) async throws -> HTTPClientResponse
    func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse
}

/// `HTTPClient` backed by Alamofire.
///
/// Wraps a `URLSession`'s configuration into an Alamofire `Session` so that any
/// protocol classes / additional headers configured on the injected session
/// (e.g. stubs in unit tests) are preserved.
struct AlamofireHTTPClient: HTTPClient {
    private let session: Session

    nonisolated init(session urlSession: URLSession = .shared) {
        let configuration = urlSession.configuration
        self.session = Session(configuration: configuration)
    }

    nonisolated func data(_ request: URLRequest) async throws -> HTTPClientResponse {
        let dataRequest = session.request(request)
        return try await response(from: dataRequest)
    }

    nonisolated func upload(_ request: URLRequest, multipart: [HTTPMultipartPart]) async throws -> HTTPClientResponse {
        let uploadRequest = session.upload(
            multipartFormData: { form in
                for part in multipart {
                    switch part {
                    case .field(let name, let value):
                        form.append(Data(value.utf8), withName: name)
                    case .file(let name, let filename, let mimeType, let data):
                        form.append(data, withName: name, fileName: filename, mimeType: mimeType)
                    }
                }
            },
            with: request
        )
        return try await response(from: uploadRequest)
    }

    nonisolated private func response(from request: DataRequest) async throws -> HTTPClientResponse {
        let response = await request.serializingResponse(
            using: EmptyTolerantDataSerializer(),
            automaticallyCancelling: true
        ).response
        switch response.result {
        case .success(let data):
            guard let http = response.response else {
                throw HTTPClientError.invalidResponse
            }
            return HTTPClientResponse(data: data, statusCode: http.statusCode)
        case .failure(let error):
            if let urlError = error.underlyingError as? URLError {
                throw urlError
            }
            throw HTTPClientError.transport(error.localizedDescription)
        }
    }

    nonisolated private func response(from request: UploadRequest) async throws -> HTTPClientResponse {
        let response = await request.serializingResponse(
            using: EmptyTolerantDataSerializer(),
            automaticallyCancelling: true
        ).response
        switch response.result {
        case .success(let data):
            guard let http = response.response else {
                throw HTTPClientError.invalidResponse
            }
            return HTTPClientResponse(data: data, statusCode: http.statusCode)
        case .failure(let error):
            if let urlError = error.underlyingError as? URLError {
                throw urlError
            }
            throw HTTPClientError.transport(error.localizedDescription)
        }
    }
}

/// Serializes the raw response body, mapping `nil`/zero-length bodies to empty
/// `Data` so that status-code based error mapping still runs for error
/// responses that carry no body.
private struct EmptyTolerantDataSerializer: ResponseSerializer {
    nonisolated func serialize(
        request: URLRequest?,
        response: HTTPURLResponse?,
        data: Data?,
        error: Error?
    ) throws -> Data {
        if let error {
            throw error
        }
        return data ?? Data()
    }
}
