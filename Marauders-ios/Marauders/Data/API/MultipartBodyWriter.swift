//
//  MultipartBodyWriter.swift
//  Marauders
//

import Foundation

/// Writes a multipart/form-data body to a file, part after part.
///
/// A part that names a file (`HTTPMultipartPart.fileAt`) is copied across in chunks, so the clip of an upload is never
/// held whole in memory while its body is built.
nonisolated enum MultipartBodyWriter {
    /// 1 MiB per read: big enough that the copy is not all system calls, small next to a clip of up to 100 MB.
    static let defaultChunkSize = 1_048_576

    /// Creates (or empties) the file at `url` and writes the body into it. A failure part-way leaves what was written
    /// so far; the caller removes the file.
    ///
    /// Runs off the caller's actor: writing a clip of up to 100 MB is a long synchronous job.
    @concurrent
    static func write(
        _ parts: [HTTPMultipartPart],
        boundary: String,
        to url: URL,
        chunkSize: Int = MultipartBodyWriter.defaultChunkSize
    ) async throws {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        for part in parts {
            switch part {
            case .field(let name, let value):
                let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escaped(name))\"\r\n\r\n"
                try handle.write(contentsOf: Data(head.utf8))
                try handle.write(contentsOf: Data(value.utf8))
            case .file(let name, let filename, let mimeType, let data):
                try handle.write(contentsOf: fileHead(boundary, name, filename, mimeType))
                try handle.write(contentsOf: data)
            case .fileAt(let name, let filename, let mimeType, let source):
                try handle.write(contentsOf: fileHead(boundary, name, filename, mimeType))
                try copy(from: source, to: handle, chunkSize: chunkSize)
            }
            try handle.write(contentsOf: Data("\r\n".utf8))
        }
        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
    }

    private static func fileHead(_ boundary: String, _ name: String, _ filename: String, _ mimeType: String) -> Data {
        let head =
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(escaped(name))\"; filename=\"\(escaped(filename))\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n"
        return Data(head.utf8)
    }

    /// Copies `source` into `destination` one chunk at a time. `FileHandle.read(upToCount:)` hands back autoreleased
    /// data: each chunk gets its own pool, or the chunks would pile up until the task ends and bring the whole clip
    /// back into memory.
    private static func copy(from source: URL, to destination: FileHandle, chunkSize: Int) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        var reachedTheEnd = false
        while !reachedTheEnd {
            try autoreleasepool {
                guard let chunk = try reader.read(upToCount: max(1, chunkSize)), !chunk.isEmpty else {
                    reachedTheEnd = true
                    return
                }
                try destination.write(contentsOf: chunk)
            }
        }
    }

    /// Percent-encodes what would end a quoted header value early, the way a browser does for a form upload.
    /// Walks unicode scalars because "\r\n" is a single `Character` and would slip past a character match.
    private static func escaped(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result.append(contentsOf: "%22".unicodeScalars)
            case "\r": result.append(contentsOf: "%0D".unicodeScalars)
            case "\n": result.append(contentsOf: "%0A".unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result)
    }
}
