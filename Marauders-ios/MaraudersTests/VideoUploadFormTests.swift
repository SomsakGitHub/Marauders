//
//  VideoUploadFormTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct VideoUploadFormTests {
    private static let bangkok = ClipLocation(latitude: 13.7563, longitude: 100.5018)!
    private static let speechCheck = ClipAudioAssessment(
        content: .mixed, speechConfidence: 0.8, musicConfidence: 0.7, signal: .detected,
        spokenLanguage: .init(status: "likely", code: "en", confidence: 0.9), sampledSeconds: 3)

    // MARK: parts

    @Test func partsAreLatitudeLongitudeSpeechCheckTrimmedCaptionThenTheFile() throws {
        let clip = URL(fileURLWithPath: "/clips/sunset.mov")

        let parts = Self.recorded(
            VideoUploadForm.parts(
                fileURL: clip,
                mimeType: "video/quicktime",
                clipLocation: Self.bangkok,
                caption: "  Sunset over Bangkok \n",
                audioAssessment: Self.speechCheck
            ))

        #expect(parts.count == 5)
        #expect(parts.first == .field(name: "latitude", value: "13.7563"))
        #expect(parts.dropFirst().first == .field(name: "longitude", value: "100.5018"))
        // The speech check travels as JSON text; its key order is the encoder's, so it is read back, not compared.
        guard parts.count == 5, case .field(name: "audioAssessment", value: let json) = parts[2] else {
            Issue.record("The third part must be the speech check")
            return
        }
        let sent = try JSONDecoder().decode(ClipAudioAssessment.self, from: Data(json.utf8))
        #expect(sent == Self.speechCheck)
        #expect(parts[3] == .field(name: "caption", value: "Sunset over Bangkok"))
        // The clip is named by its URL, never read into the part, and it comes last.
        #expect(parts[4] == .fileAt(name: "file", filename: "sunset.mov", mimeType: "video/quicktime", url: clip))
    }

    @Test func anEmptyCaptionAndNoSpeechCheckAddNoPart() {
        let clip = URL(fileURLWithPath: "/clips/sunset.mp4")

        let parts = Self.recorded(
            VideoUploadForm.parts(
                fileURL: clip,
                mimeType: "video/mp4",
                clipLocation: Self.bangkok,
                caption: " \n\t ",
                audioAssessment: nil
            ))

        #expect(
            parts == [
                .field(name: "latitude", value: "13.7563"),
                .field(name: "longitude", value: "100.5018"),
                .fileAt(name: "file", filename: "sunset.mp4", mimeType: "video/mp4", url: clip),
            ])
    }

    // MARK: validatedSize

    @Test func validatedSizeRefusesAnUnsupportedTypeAnEmptyFileAndAFileOverTheLimit() throws {
        let clip = try TestFixtureFiles.temporaryVideoFile(byteCount: 64)
        let empty = try TestFixtureFiles.temporaryVideoFile(byteCount: 0)
        let atTheLimit = try Self.sparseFile(byteCount: VideoUploadForm.maxUploadBytes)
        let overTheLimit = try Self.sparseFile(byteCount: VideoUploadForm.maxUploadBytes + 1)
        defer { for url in [clip, empty, atTheLimit, overTheLimit] { try? FileManager.default.removeItem(at: url) } }

        // The cap is 100 MiB, and the client that used to own it still reads it from the form.
        #expect(VideoUploadForm.maxUploadBytes == 100 * 1024 * 1024)
        #expect(VideoUploadAPIClient.maxUploadBytes == VideoUploadForm.maxUploadBytes)

        // What passes: both video types, and the answer is the clip's size (the cap itself is not over it).
        #expect(try VideoUploadForm.validatedSize(of: clip, mimeType: "video/mp4") == 64)
        #expect(try VideoUploadForm.validatedSize(of: clip, mimeType: "video/quicktime") == 64)
        #expect(
            try VideoUploadForm.validatedSize(of: atTheLimit, mimeType: "video/mp4") == VideoUploadForm.maxUploadBytes)

        // What does not: any other type (decided before the file is even looked at), an empty file, one byte too many.
        #expect(throws: VideoUploadAPIError.unsupportedFormat) {
            try VideoUploadForm.validatedSize(of: clip, mimeType: "image/jpeg")
        }
        #expect(throws: VideoUploadAPIError.unsupportedFormat) {
            try VideoUploadForm.validatedSize(of: URL(fileURLWithPath: "/clips/gone.mp4"), mimeType: "image/jpeg")
        }
        #expect(throws: VideoUploadAPIError.fileTooLarge) {
            try VideoUploadForm.validatedSize(of: empty, mimeType: "video/mp4")
        }
        #expect(throws: VideoUploadAPIError.fileTooLarge) {
            try VideoUploadForm.validatedSize(of: overTheLimit, mimeType: "video/mp4")
        }
    }

    // MARK: request

    @Test func theRequestCarriesTheBearerTheBoundaryAndALowerCaseKey() throws {
        let key = try #require(UUID(uuidString: "5F3A9C1E-7B2D-4E86-A0C4-D81E92B7F3A6"))

        let uploadURL = try APIConfiguration.videoUploadURL()

        let request = try VideoUploadForm.request(
            authorizationHeader: "Bearer abc.def", boundary: "marauders.boundary.TEST", idempotencyKey: key)

        #expect(request.httpMethod == "POST")
        // Compared as text: `videoUploadURL()` is relative to the base URL, and a request hands back the absolute one.
        #expect(request.url?.absoluteString == uploadURL.absoluteString)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc.def")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=marauders.boundary.TEST"
        )
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "5f3a9c1e-7b2d-4e86-a0c4-d81e92b7f3a6")
        #expect(request.timeoutInterval == 300)
    }

    @Test func aRequestWithoutBoundaryOrKeyCarriesNeither() throws {
        let uploadURL = try APIConfiguration.videoUploadURL()

        let request = try VideoUploadForm.request(authorizationHeader: "Bearer abc.def")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == uploadURL.absoluteString)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc.def")
        // The HTTP client adds the multipart type and its own boundary when it sends the parts.
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect(request.timeoutInterval == 300)
    }

    // MARK: decodeItem

    @Test func decodeItemRefusesAStreamUrlThatIsNotHttpsAndABodyThatIsNotAClip() throws {
        let id = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        // What it accepts: the item of an HTTPS answer.
        let item = try VideoUploadForm.decodeItem(
            from: Self.answer(id: id, streamURL: "https://cdn.example.com/v/new.mp4"))
        #expect(item.id == id)
        #expect(item.streamURL.absoluteString == "https://cdn.example.com/v/new.mp4")

        // What it refuses: a stream URL that is not HTTPS, and anything that is not an upload answer.
        let refused = [
            Self.answer(id: id, streamURL: "http://insecure.example.com/v.mp4"),
            Self.answer(id: id, streamURL: "cdn.example.com/v.mp4"),
            Data(#"{"item":{"id":"22222222-2222-2222-2222-222222222222"}}"#.utf8),
            Data(#"{"error":"Upload failed"}"#.utf8),
            Data("not json".utf8),
            Data(),
        ]
        for body in refused {
            #expect(throws: VideoUploadAPIError.invalidResponse) {
                try VideoUploadForm.decodeItem(from: body)
            }
        }
    }

    // MARK: serverMessage

    @Test func serverMessageReadsTheErrorField() {
        #expect(
            VideoUploadForm.serverMessage(from: Data(#"{"error":"File exceeds allowed size"}"#.utf8))
                == "File exceeds allowed size")
        #expect(VideoUploadForm.serverMessage(from: Data(#"{"message":"File exceeds allowed size"}"#.utf8)) == nil)
        #expect(VideoUploadForm.serverMessage(from: Data(#"{"error":413}"#.utf8)) == nil)
        #expect(VideoUploadForm.serverMessage(from: Data("not json".utf8)) == nil)
        #expect(VideoUploadForm.serverMessage(from: Data()) == nil)
    }
}

// MARK: - Helpers

extension VideoUploadFormTests {
    /// `HTTPMultipartPart` cannot be compared, so a test reads it through `RecordingTransport.RecordedPart`, its twin.
    fileprivate static func recorded(_ parts: [HTTPMultipartPart]) -> [RecordingTransport.RecordedPart] {
        parts.map { part in
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

    /// A file that reads as `byteCount` bytes and takes no disk space: the file system fills the gap with zeros.
    fileprivate static func sparseFile(byteCount: Int64) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
        return url
    }

    /// What the Worker answers to an upload: `{"item": {"id": ..., "streamURL": ...}}`.
    fileprivate static func answer(id: UUID, streamURL: String) -> Data {
        let payload: [String: Any] = ["item": ["id": id.uuidString, "streamURL": streamURL]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
