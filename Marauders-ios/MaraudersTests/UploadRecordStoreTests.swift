//
//  UploadRecordStoreTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// Every test works in a folder of its own under `NSTemporaryDirectory()` and removes it afterwards; none touches the
/// app's real `Application Support/PendingUpload`.
struct UploadRecordStoreTests {
    private static func record(
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        state: UploadRecordState = .uploading(fraction: 0, refreshedOnce: false)
    ) -> UploadRecord {
        UploadRecord(
            version: UploadRecord.currentVersion,
            id: id,
            accountSubject: "001234.abcdef.5678",
            bodyFileName: "\(id.uuidString.lowercased()).multipart",
            boundary: "marauders.boundary.\(UUID().uuidString)",
            byteCount: 2_048,
            createdAt: createdAt,
            state: state
        )
    }

    /// Runs `body` with a folder that holds nothing yet, and removes the folder whatever `body` does.
    private static func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "upload-record-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    /// Runs `body` with a store whose directory has been prepared.
    private static func withStore(_ body: (UploadRecordStore) throws -> Void) throws {
        try withFolder { folder in
            let store = UploadRecordStore(
                directory: folder.appending(path: "PendingUpload", directoryHint: .isDirectory))
            try store.prepareDirectory()
            try body(store)
        }
    }

    private static func writeBody(of id: UUID, in store: UploadRecordStore) throws {
        try Data("multipart body of \(id)".utf8).write(to: store.bodyURL(id: id))
    }

    private static func names(in store: UploadRecordStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
    }

    @Test func aSavedRecordComesBackEqual() throws {
        try Self.withStore { store in
            let record = Self.record()

            try store.save(record)

            #expect(store.records() == [record])

            // Saving again replaces the record, as every change of state does.
            var settled = record
            settled.state = .failed(.interrupted)
            try store.save(settled)

            #expect(store.records() == [settled])
            #expect(try Self.names(in: store) == ["\(record.id.uuidString.lowercased()).json"])

            // Several records come back oldest first, whatever order the directory lists them in.
            let older = Self.record(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            let newer = Self.record(createdAt: Date(timeIntervalSince1970: 1_900_000_000))
            try store.save(newer)
            try store.save(older)

            #expect(store.records() == [older, settled, newer])
        }
    }

    @Test func deletingRemovesTheRecordAndItsBody() throws {
        try Self.withStore { store in
            let doomed = Self.record()
            let neighbour = Self.record()
            for record in [doomed, neighbour] {
                try store.save(record)
                try Self.writeBody(of: record.id, in: store)
            }

            store.delete(id: doomed.id)

            #expect(store.records() == [neighbour])
            #expect(store.bodyExists(id: doomed.id) == false)
            #expect(store.bodyExists(id: neighbour.id))
            #expect(
                try Self.names(in: store) == [
                    "\(neighbour.id.uuidString.lowercased()).json", "\(neighbour.id.uuidString.lowercased()).multipart",
                ])

            // A record that is not there is nothing to delete.
            store.delete(id: doomed.id)
            #expect(store.records() == [neighbour])
        }
    }

    @Test func deletingTheBodyKeepsTheRecord() throws {
        try Self.withStore { store in
            let record = Self.record()
            try store.save(record)
            try Self.writeBody(of: record.id, in: store)
            #expect(store.bodyExists(id: record.id))

            store.deleteBody(id: record.id)

            #expect(store.bodyExists(id: record.id) == false)
            #expect(store.records() == [record])
        }
    }

    @Test func anUnreadableOrOtherVersionRecordFileIsDeletedWhenListing() throws {
        try Self.withStore { store in
            let good = Self.record()
            try store.save(good)
            try Self.writeBody(of: good.id, in: store)

            // Bytes that are not JSON, JSON that is not a record, and a record of a version this build does not read.
            let notJSON = store.directory.appending(path: "\(UUID().uuidString.lowercased()).json")
            try Data("this is not json".utf8).write(to: notJSON)
            let notARecord = store.directory.appending(path: "\(UUID().uuidString.lowercased()).json")
            try Data(#"{"hello":"world"}"#.utf8).write(to: notARecord)
            var future = Self.record()
            future.version = UploadRecord.currentVersion + 1
            try store.save(future)
            var ancient = Self.record()
            ancient.version = UploadRecord.currentVersion - 1
            try store.save(ancient)

            #expect(store.records() == [good])

            // Only the good record and its body are left in the directory.
            #expect(
                try Self.names(in: store) == [
                    "\(good.id.uuidString.lowercased()).json", "\(good.id.uuidString.lowercased()).multipart",
                ])
        }
    }

    @Test func anOrphanBodyIsRemovedAndABodyWithARecordIsKept() throws {
        try Self.withStore { store in
            let kept = Self.record()
            try store.save(kept)
            try Self.writeBody(of: kept.id, in: store)
            let orphan = UUID()
            try Self.writeBody(of: orphan, in: store)
            // A record file that cannot be read names no body: what it left behind is an orphan too.
            let unreadable = UUID()
            try Data("this is not json".utf8).write(
                to: store.directory.appending(path: "\(unreadable.uuidString.lowercased()).json"))
            try Self.writeBody(of: unreadable, in: store)

            store.removeOrphanBodies()

            #expect(store.bodyExists(id: kept.id))
            #expect(store.bodyExists(id: orphan) == false)
            #expect(store.bodyExists(id: unreadable) == false)
            #expect(store.records() == [kept])
        }
    }

    @Test func theDirectoryIsExcludedFromBackup() throws {
        try Self.withFolder { folder in
            // Neither the directory nor the folder above it exists yet.
            let store = UploadRecordStore(
                directory: folder.appending(path: "Library/PendingUpload", directoryHint: .isDirectory))

            try store.prepareDirectory()

            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            #expect(
                try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

            // Preparing it again, as every staging does, keeps what is in it and the exclusion.
            let record = Self.record()
            try store.save(record)
            try store.prepareDirectory()
            #expect(store.records() == [record])
            #expect(
                try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }

    @Test func theStandardDirectoryIsPendingUploadInApplicationSupport() {
        // Only the place is checked: nothing here creates or reads the app's real directory.
        #expect(UploadRecordStore.standardDirectory.lastPathComponent == "PendingUpload")
        #expect(
            UploadRecordStore.standardDirectory.deletingLastPathComponent().path
                == URL.applicationSupportDirectory.path)
    }
}
