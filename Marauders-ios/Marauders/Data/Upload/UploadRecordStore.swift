//
//  UploadRecordStore.swift
//  Marauders
//

import Foundation

/// Keeps the pending upload on disk: per upload a record file and the staged body, side by side in one directory and
/// named by the id in lower case, `<id>.json` and `<id>.multipart`.
///
/// Synchronous, and silent about a file that is already gone, so the uploader can use it from anywhere. The directory
/// is excluded from backup. Its files keep the default file protection, never `.complete`: a locked iPhone must still
/// be able to read the body.
nonisolated struct UploadRecordStore: Sendable {
    let directory: URL

    /// `Application Support/PendingUpload`.
    static var standardDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "PendingUpload", directoryHint: .isDirectory)
    }

    /// Creates the directory, and its parents, and keeps it out of backup. Safe to call again on a directory that is
    /// ready: nothing in it is touched.
    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    /// The records on disk, the oldest first. A record file that cannot be read, or has another version than
    /// `UploadRecord.currentVersion`, can never be used and is deleted.
    func records() -> [UploadRecord] {
        var readable: [UploadRecord] = []
        for file in files(withExtension: "json") {
            if let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(UploadRecord.self, from: data),
                record.version == UploadRecord.currentVersion
            {
                readable.append(record)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return readable.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Writes the record, replacing the one of the same id, in one piece: a reader sees the old file or the new one.
    func save(_ record: UploadRecord) throws {
        try JSONEncoder().encode(record).write(to: recordURL(id: record.id), options: .atomic)
    }

    /// Deletes the record and its body. The record goes first, so a crash half-way never leaves a record whose body is
    /// gone; a body left behind is an orphan, and `removeOrphanBodies` takes it.
    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: recordURL(id: id))
        deleteBody(id: id)
    }

    /// Deletes the body and keeps the record.
    func deleteBody(id: UUID) {
        try? FileManager.default.removeItem(at: bodyURL(id: id))
    }

    /// Where the body of `id` is, or will be.
    func bodyURL(id: UUID) -> URL {
        directory.appending(path: "\(Self.name(of: id)).multipart", directoryHint: .notDirectory)
    }

    func bodyExists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: bodyURL(id: id).path)
    }

    /// Deletes every body no record on disk belongs to, such as one whose staging was cut short, or one whose record
    /// file could not be read (that file is deleted too, as in `records()`).
    ///
    /// Call it only while no body is being staged: a body counts as an orphan from the moment it is written until its
    /// record is saved.
    func removeOrphanBodies() {
        let owned = Set(records().map { bodyURL(id: $0.id).lastPathComponent })
        for file in files(withExtension: "multipart") where !owned.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func recordURL(id: UUID) -> URL {
        directory.appending(path: "\(Self.name(of: id)).json", directoryHint: .notDirectory)
    }

    private static func name(of id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private func files(withExtension pathExtension: String) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return (contents ?? []).filter { $0.pathExtension == pathExtension }
    }
}
