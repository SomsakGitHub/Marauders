//
//  VideoUploadAPIClientTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

@Suite(.serialized)
@MainActor
struct VideoUploadAPIClientTests {
    private static let sampleClipLocation = ClipLocation(latitude: 13.7563, longitude: 100.5018)!
    private static let testAuthorization = StubTestAPIAuthorization()

    private static func authorizedClient(session: URLSession) -> VideoUploadAPIClient {
        VideoUploadAPIClient(session: session, authorization: testAuthorization)
    }
    @Test func uploadRejectsUnsupportedMimeBeforeNetwork() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = StubURLSessionFactory.make { request in
            Issue.record("Network must not run for invalid MIME")
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = Self.authorizedClient(session: session)

        await #expect(throws: VideoUploadAPIError.unsupportedFormat) {
            try await client.upload(
                fileURL: fileURL,
                mimeType: "image/jpeg",
                clipLocation: Self.sampleClipLocation
            )
        }
    }

    @Test func uploadRejectsEmptyFileBeforeNetwork() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 0)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = Self.authorizedClient(session: URLSession(configuration: .ephemeral))

        await #expect(throws: VideoUploadAPIError.fileTooLarge) {
            try await client.upload(
                fileURL: fileURL,
                mimeType: "video/mp4",
                clipLocation: Self.sampleClipLocation
            )
        }
    }

    @Test func uploadSuccessDecodesHTTPSItem() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 128)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let videoID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let body = VideoUploadAPIClientTests.uploadResponseJSON(
            id: videoID,
            streamURL: "https://cdn.example.com/v/new.mp4"
        )

        var capturedRequest: URLRequest?
        let session = StubURLSessionFactory.make { request in
            capturedRequest = request
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 201)
            return (response, body)
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = Self.authorizedClient(session: session)
        let item = try await client.upload(
            fileURL: fileURL,
            mimeType: "video/mp4",
            clipLocation: Self.sampleClipLocation
        )

        #expect(item.id == videoID)
        #expect(item.streamURL.absoluteString == "https://cdn.example.com/v/new.mp4")
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.url?.path().hasSuffix("/v1/videos") == true)
        let contentType = capturedRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    }

    @Test func uploadSendsCaptionField() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var capturedBody = Data()
        let session = StubURLSessionFactory.make { request in
            capturedBody = Self.bodyData(from: request)
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 201)
            return (response, Self.uploadResponseJSON(id: UUID(), streamURL: "https://cdn.example.com/v.mp4"))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = Self.authorizedClient(session: session)
        _ = try await client.upload(
            fileURL: fileURL,
            mimeType: "video/mp4",
            clipLocation: Self.sampleClipLocation,
            caption: "Sunset over Bangkok"
        )

        let body = String(decoding: capturedBody, as: UTF8.self)
        #expect(body.contains("name=\"caption\""))
        #expect(body.contains("Sunset over Bangkok"))
        #expect(!body.contains("name=\"musicTitle\""))
    }

    @Test func uploadOmitsEmptyCaption() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var capturedBody = Data()
        let session = StubURLSessionFactory.make { request in
            capturedBody = Self.bodyData(from: request)
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 201)
            return (response, Self.uploadResponseJSON(id: UUID(), streamURL: "https://cdn.example.com/v.mp4"))
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = Self.authorizedClient(session: session)
        _ = try await client.upload(
            fileURL: fileURL,
            mimeType: "video/mp4",
            clipLocation: Self.sampleClipLocation,
            caption: "   "
        )

        let body = String(decoding: capturedBody, as: UTF8.self)
        #expect(!body.contains("name=\"caption\""))
    }

    @Test func uploadSurfacesServerErrorMessage() async throws {        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let message = "File exceeds allowed size"
        let body = Data("{\"error\":\"\(message)\"}".utf8)
        let session = StubURLSessionFactory.make { request in
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 413)
            return (response, body)
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = Self.authorizedClient(session: session)

        do {
            _ = try await client.upload(
                fileURL: fileURL,
                mimeType: "video/mp4",
                clipLocation: Self.sampleClipLocation
            )
            Issue.record("Expected upload to fail")
        } catch {
            #expect(error.localizedDescription == message)
        }
    }

    @Test func uploadMapsServerErrorWithoutJSONBody() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = StubURLSessionFactory.make { request in
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 503)
            return (response, Data())
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = Self.authorizedClient(session: session)

        await #expect(throws: VideoUploadAPIError.serverError(503)) {
            try await client.upload(
                fileURL: fileURL,
                mimeType: "video/mp4",
                clipLocation: Self.sampleClipLocation
            )
        }
    }

    @Test func uploadRejectsNonHTTPSStreamURLInResponse() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let body = VideoUploadAPIClientTests.uploadResponseJSON(
            id: UUID(),
            streamURL: "http://insecure.example.com/v.mp4"
        )
        let session = StubURLSessionFactory.make { request in
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, body)
        }
        defer { StubURLSessionFactory.reset(session) }

        let client = Self.authorizedClient(session: session)

        await #expect(throws: VideoUploadAPIError.invalidResponse) {
            try await client.upload(
                fileURL: fileURL,
                mimeType: "video/mp4",
                clipLocation: Self.sampleClipLocation
            )
        }
    }
}

private struct StubTestAPIAuthorization: APIAuthorization {
    func bearerAuthorizationHeader() -> String? {
        "Bearer \(String(repeating: "t", count: 40))"
    }
}

private extension VideoUploadAPIClientTests {
    static func uploadResponseJSON(id: UUID, streamURL: String) -> Data {
        let payload: [String: Any] = [
            "item": [
                "id": id.uuidString,
                "streamURL": streamURL,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
