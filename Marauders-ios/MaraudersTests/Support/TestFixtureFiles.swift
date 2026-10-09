//
//  TestFixtureFiles.swift
//  MaraudersTests
//

import Foundation

enum TestFixtureFiles {
    static func temporaryVideoFile(byteCount: Int, extension ext: String = "mp4") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
            .appendingPathExtension(ext)
        let data = Data(repeating: 0xAB, count: max(byteCount, 0))
        try data.write(to: url, options: .atomic)
        return url
    }
}
