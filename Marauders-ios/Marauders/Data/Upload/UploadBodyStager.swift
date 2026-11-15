//
//  UploadBodyStager.swift
//  Marauders
//

import Foundation

/// Writes the body of an upload into the store's directory before the request goes out: a background `URLSession` sends
/// a file, and the file has to outlive the app.
nonisolated struct UploadBodyStager: Sendable {
    /// A staged body: the boundary it was written with and its size in bytes.
    struct Staged: Equatable, Sendable {
        let boundary: String
        let byteCount: Int64
    }

    private let store: UploadRecordStore
    private let freeSpaceMargin: Int64
    private let availableBytes: @Sendable (URL) -> Int64

    /// - Parameters:
    ///   - freeSpaceMargin: How much free space has to remain beyond the clip's own size: 50 MiB, for the form around
    ///     the clip and for the rest of the phone.
    ///   - availableBytes: The bytes available on the volume of a directory. The system's figure, unless a test says
    ///     otherwise.
    init(
        store: UploadRecordStore,
        freeSpaceMargin: Int64 = 52_428_800,
        availableBytes: @escaping @Sendable (URL) -> Int64 = UploadBodyStager.systemAvailableBytes
    ) {
        self.store = store
        self.freeSpaceMargin = freeSpaceMargin
        self.availableBytes = availableBytes
    }

    /// The bytes the system makes available for important usage on the volume of `directory`; 0 when it cannot say.
    /// Reading this is a required-reason API: `PrivacyInfo.xcprivacy` declares `E174.1` for it.
    static func systemAvailableBytes(_ directory: URL) -> Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Writes the body of `id` and tells how it was written. Throws `ClipUploadError.notEnoughSpace`, with nothing
    /// written, when the phone has less than the clip's size plus the margin to spare. A failure while writing deletes
    /// the part that was written.
    ///
    /// Runs off the caller's actor: writing a clip of up to 100 MB is a long synchronous job.
    @concurrent
    func stage(id: UUID, parts: [HTTPMultipartPart], clipByteCount: Int64) async throws -> Staged {
        // The free space is read from the directory, so it has to exist first.
        try store.prepareDirectory()
        guard availableBytes(store.directory) >= clipByteCount + freeSpaceMargin else {
            throw ClipUploadError.notEnoughSpace
        }

        let boundary = "marauders.boundary.\(UUID().uuidString)"
        let body = store.bodyURL(id: id)
        do {
            try await MultipartBodyWriter.write(parts, boundary: boundary, to: body)
            let attributes = try FileManager.default.attributesOfItem(atPath: body.path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
                throw CocoaError(.fileReadUnknown)
            }
            return Staged(boundary: boundary, byteCount: size)
        } catch {
            store.deleteBody(id: id)
            throw error
        }
    }
}
