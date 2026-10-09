//
//  TemporaryFileCleanupTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

struct TemporaryFileCleanupTests {
    @Test func deletesFileInTemporaryDirectory() throws {
        let url = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        #expect(FileManager.default.fileExists(atPath: url.path))

        TemporaryFileCleanup.deleteIfTemporary(url)

        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func doesNotDeleteFileOutsideTemporaryDirectory() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("staging-guard-\(UUID().uuidString).mp4")
        try Data([0xAB]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        TemporaryFileCleanup.deleteIfTemporary(url)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
