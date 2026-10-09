//
//  TemporaryFileCleanup.swift
//  Marauders
//

import Foundation

/// Deletes user-generated staging files only under the app temporary directory.
enum TemporaryFileCleanup {
    nonisolated static func deleteIfTemporary(_ url: URL?) {
        guard let url, isTemporary(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func isTemporary(_ url: URL) -> Bool {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL
            .path
        return url.standardizedFileURL.path.hasPrefix(temporaryRoot)
    }
}
