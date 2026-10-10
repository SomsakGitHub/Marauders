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
    @Test func uploadRejectsUnsupportedMimeBeforeNetwork() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = StubURLSessionFactory.make { request in
            Issue.record("Network must not run for invalid MIME")
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 200)
            return (response, Data())
        }
        defer { StubURLSessionFactory.reset() }

        let client = VideoUploadAPIClient(session: session)

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

        let client = VideoUploadAPIClient(session: URLSession(configuration: .ephemeral))

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
        defer { StubURLSessionFactory.reset() }

        let client = VideoUploadAPIClient(session: session)
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

    @Test func uploadSurfacesServerErrorMessage() async throws {
        let fileURL = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let message = "File exceeds allowed size"
        let body = Data("{\"error\":\"\(message)\"}".utf8)
        let session = StubURLSessionFactory.make { request in
            let response = StubURLSessionFactory.httpResponse(for: request, statusCode: 413)
            return (response, body)
        }
        defer { StubURLSessionFactory.reset() }

        let client = VideoUploadAPIClient(session: session)

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
        defer { StubURLSessionFactory.reset() }

        let client = VideoUploadAPIClient(session: session)

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
        defer { StubURLSessionFactory.reset() }

        let client = VideoUploadAPIClient(session: session)

        await #expect(throws: VideoUploadAPIError.invalidResponse) {
            try await client.upload(
                fileURL: fileURL,
                mimeType: "video/mp4",
                clipLocation: Self.sampleClipLocation
            )
        }
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
}
