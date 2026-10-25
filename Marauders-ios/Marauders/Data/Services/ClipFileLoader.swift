import Foundation

/// Downloads a clip for on-device processing, refusing anything over the size limit.
struct ClipFileLoader: ClipFileLoading {
    static let maximumBytes = 12 * 1024 * 1024

    func load(_ url: URL, into folder: URL, check: () throws -> Void) async throws -> URL {
        if url.isFileURL { return url }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DubbingError.failed }
        guard response.expectedContentLength <= Self.maximumBytes else { throw DubbingError.unsupported }
        var data = Data()
        for try await byte in bytes {
            if data.count % 65536 == 0 { try check() }
            guard data.count < Self.maximumBytes else { throw DubbingError.unsupported }
            data.append(byte)
        }
        let file = folder.appendingPathComponent("source.mp4")
        try data.write(to: file)
        return file
    }
}
