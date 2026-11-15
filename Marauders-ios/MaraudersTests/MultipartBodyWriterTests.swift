//
//  MultipartBodyWriterTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct MultipartBodyWriterTests {
    /// Sizes that fall on and around the edges of a 4-byte chunk: empty, short of a chunk, exactly one, one over,
    /// exactly two, and two with a rest.
    @Test(arguments: [0, 1, 3, 4, 5, 8, 11])
    func aFileBackedPartMakesTheSameBodyAsTheSameBytesInMemory(size: Int) async throws {
        // Neither all zeros nor a repeating block of four, so a lost, doubled or shifted chunk shows.
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("clip.mp4")
        try bytes.write(to: clip)
        let fromDisk = folder.appendingPathComponent("from-disk.multipart")
        let fromMemory = folder.appendingPathComponent("from-memory.multipart")

        try await MultipartBodyWriter.write(
            [
                .field(name: "latitude", value: "13.5"),
                .fileAt(name: "file", filename: "clip.mp4", mimeType: "video/mp4", url: clip),
            ],
            boundary: "b", to: fromDisk, chunkSize: 4)
        try await MultipartBodyWriter.write(
            [
                .field(name: "latitude", value: "13.5"),
                .file(name: "file", filename: "clip.mp4", mimeType: "video/mp4", data: bytes),
            ],
            boundary: "b", to: fromMemory, chunkSize: 4)

        #expect(try Data(contentsOf: fromDisk) == Data(contentsOf: fromMemory))
    }

    @Test func aMissingSourceFileThrows() async throws {
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("gone.mp4")

        await #expect(throws: (any Error).self) {
            try await MultipartBodyWriter.write(
                [.fileAt(name: "file", filename: "gone.mp4", mimeType: "video/mp4", url: missing)],
                boundary: "b", to: folder.appendingPathComponent("body.multipart"))
        }
    }

    private static func makeScratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-body-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
