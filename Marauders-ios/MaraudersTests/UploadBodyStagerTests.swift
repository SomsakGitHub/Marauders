//
//  UploadBodyStagerTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// Every test works in a folder of its own under `NSTemporaryDirectory()` and removes it afterwards; none touches the
/// app's real `Application Support/PendingUpload`.
struct UploadBodyStagerTests {
    /// The free space the plan asks to keep beyond the clip: 50 MiB.
    private static let margin: Int64 = 52_428_800

    /// A clip on disk and the form that carries it, with a store whose directory sits beside the clip, not in it.
    private struct Staging {
        let folder: URL
        let clip: URL
        let clipByteCount: Int64
        let store: UploadRecordStore
        let parts: [HTTPMultipartPart]
        let id = UUID()
    }

    private static func withStaging(_ body: (Staging) async throws -> Void) async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "upload-body-stager-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Neither all zeros nor a repeating block, so a lost, doubled or shifted chunk shows.
        let bytes = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let clip = folder.appending(path: "clip.mp4")
        try bytes.write(to: clip)
        let parts: [HTTPMultipartPart] = [
            .field(name: "latitude", value: "13.7563"),
            .field(name: "longitude", value: "100.5018"),
            .field(name: "caption", value: "Sunset over Bangkok"),
            .fileAt(name: "file", filename: "clip.mp4", mimeType: "video/mp4", url: clip),
        ]
        try await body(
            Staging(
                folder: folder, clip: clip, clipByteCount: Int64(bytes.count),
                store: UploadRecordStore(
                    directory: folder.appending(path: "PendingUpload", directoryHint: .isDirectory)),
                parts: parts))
    }

    private static func fileNames(in store: UploadRecordStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
    }

    /// A stager that reports `available` bytes free in the store's directory, and nothing for any other place.
    private static func stager(_ staging: Staging, available: Int64) -> UploadBodyStager {
        let directory = staging.store.directory
        return UploadBodyStager(store: staging.store, availableBytes: { $0 == directory ? available : 0 })
    }

    @Test func theBodyOnDiskIsWhatTheWriterMakesForTheSamePartsAndBoundary() async throws {
        try await Self.withStaging { staging in
            let stager = Self.stager(staging, available: .max)

            let staged = try await stager.stage(
                id: staging.id, parts: staging.parts, clipByteCount: staging.clipByteCount)

            // The boundary is the one the plan names, with a fresh UUID.
            #expect(staged.boundary.hasPrefix("marauders.boundary."))
            #expect(UUID(uuidString: String(staged.boundary.dropFirst("marauders.boundary.".count))) != nil)
            // The body is the file the writer makes for the same parts and boundary, byte for byte, where the store
            // keeps the body of this id.
            let reference = staging.folder.appending(path: "reference.multipart")
            try await MultipartBodyWriter.write(staging.parts, boundary: staged.boundary, to: reference)
            #expect(try Data(contentsOf: staging.store.bodyURL(id: staging.id)) == Data(contentsOf: reference))
            #expect(
                staging.store.bodyURL(id: staging.id).lastPathComponent
                    == "\(staging.id.uuidString.lowercased()).multipart")
        }
    }

    @Test func theByteCountIsTheSizeOfTheBodyFile() async throws {
        try await Self.withStaging { staging in
            let stager = Self.stager(staging, available: .max)

            let staged = try await stager.stage(
                id: staging.id, parts: staging.parts, clipByteCount: staging.clipByteCount)

            let onDisk = try Data(contentsOf: staging.store.bodyURL(id: staging.id))
            #expect(staged.byteCount == Int64(onDisk.count))
            // The body holds the clip and the form around it.
            #expect(staged.byteCount > staging.clipByteCount)
        }
    }

    @Test func notEnoughFreeSpaceThrowsBeforeAnythingIsWritten() async throws {
        try await Self.withStaging { staging in
            // One byte short of the clip and the margin, with the margin the stager has unless it is told another.
            let stager = Self.stager(staging, available: staging.clipByteCount + Self.margin - 1)

            await #expect(throws: ClipUploadError.notEnoughSpace) {
                try await stager.stage(id: staging.id, parts: staging.parts, clipByteCount: staging.clipByteCount)
            }

            #expect(staging.store.bodyExists(id: staging.id) == false)
            let leftovers = try Self.fileNames(in: staging.store)
            #expect(leftovers.isEmpty)
        }
    }

    @Test func exactlyTheClipPlusTheMarginIsEnough() async throws {
        try await Self.withStaging { staging in
            let stager = Self.stager(staging, available: staging.clipByteCount + Self.margin)

            let staged = try await stager.stage(
                id: staging.id, parts: staging.parts, clipByteCount: staging.clipByteCount)

            #expect(staging.store.bodyExists(id: staging.id))
            #expect(staged.byteCount > 0)
        }
    }

    @Test func aMissingClipFileLeavesNoBodyBehind() async throws {
        try await Self.withStaging { staging in
            let stager = Self.stager(staging, available: .max)
            // The form is written part by part, so the fields are on disk by the time the clip is found to be gone.
            let parts: [HTTPMultipartPart] = [
                .field(name: "latitude", value: "13.7563"),
                .fileAt(
                    name: "file", filename: "gone.mp4", mimeType: "video/mp4",
                    url: staging.folder.appending(path: "gone.mp4")),
            ]

            await #expect(throws: (any Error).self) {
                try await stager.stage(id: staging.id, parts: parts, clipByteCount: staging.clipByteCount)
            }

            #expect(staging.store.bodyExists(id: staging.id) == false)
            let leftovers = try Self.fileNames(in: staging.store)
            #expect(leftovers.isEmpty)
        }
    }

    @Test func theBodyFileHasNoCompleteProtection() async throws {
        try await Self.withStaging { staging in
            let stager = Self.stager(staging, available: .max)
            _ = try await stager.stage(id: staging.id, parts: staging.parts, clipByteCount: staging.clipByteCount)

            // A locked phone must still be able to read the body, so the file keeps the default protection. The
            // value is compared as the text the system gives it: a failed cast to FileProtectionType would pass for
            // any file.
            let attributes = try FileManager.default.attributesOfItem(
                atPath: staging.store.bodyURL(id: staging.id).path)
            let protection = attributes[.protectionKey].map { "\($0)" }
            #expect(protection != FileProtectionType.complete.rawValue)
        }
    }

    @Test func theSystemFigureIsPositiveForAFolderThatExistsAndZeroForOneThatDoesNot() async throws {
        try await Self.withStaging { staging in
            #expect(UploadBodyStager.systemAvailableBytes(staging.folder) > 0)
            #expect(UploadBodyStager.systemAvailableBytes(staging.folder.appending(path: "nothing-here")) == 0)
        }
    }
}
