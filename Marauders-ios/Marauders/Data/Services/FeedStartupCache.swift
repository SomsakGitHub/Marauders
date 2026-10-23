import AVFoundation
import Foundation

protocol FeedStartupCaching: Sendable {
    func cachedVideos() async -> [FeedVideo]
    func store(_ videos: [FeedVideo]) async
}

/// A small, disposable cache of complete files. Remote URLs remain the source of truth.
actor FeedStartupCache: FeedStartupCaching {
    static let shared = FeedStartupCache()
    private struct Entry: Codable {
        let video: FeedVideo
        let savedAt: Date
    }
    private let directory: URL
    private let download: @Sendable (URLRequest, Int64) async throws -> (URL, URLResponse)
    private let maxFileBytes: Int64
    private let lifetime: TimeInterval
    private let validate: @Sendable (URL) async -> Bool
    private var isStoring = false

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "FeedStartup-v1", directoryHint: .isDirectory),
         download: @escaping @Sendable (URLRequest, Int64) async throws -> (URL, URLResponse) = { request, limit in
             try await FeedCacheDownloader.download(request, limit: limit)
         }, maxFileBytes: Int64 = 12 * 1024 * 1024,
         lifetime: TimeInterval = 6 * 60 * 60,
         validate: @escaping @Sendable (URL) async -> Bool = { url in
             (try? await AVURLAsset(url: url).load(.isPlayable)) == true
         }) {
        self.directory = directory
        self.download = download
        self.maxFileBytes = maxFileBytes
        self.lifetime = lifetime
        self.validate = validate
    }

    private var manifest: URL { directory.appending(path: "manifest.json") }
    private func file(for video: FeedVideo) -> URL {
        directory.appending(path: video.id.uuidString + ".mp4")
    }
    private func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(entries.prefix(2)).filter {
            $0.video.streamURL.scheme?.lowercased() == "https"
                && Date().timeIntervalSince($0.savedAt) >= 0
                && Date().timeIntervalSince($0.savedAt) < lifetime
                && fileSize(file(for: $0.video)) > 0
                && fileSize(file(for: $0.video)) <= maxFileBytes
        }
    }
    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    func cachedVideos() async -> [FeedVideo] {
        if !isStoring { pruneFiles() }
        var result: [FeedVideo] = []
        for entry in entries() {
            if await validate(file(for: entry.video)) { result.append(entry.video) }
            else { invalidate(entry.video.streamURL) }
        }
        return result
    }

    func localURL(for remote: URL) -> URL? {
        entries().first { $0.video.streamURL == remote }.map { file(for: $0.video) }
    }

    func invalidate(_ remote: URL) {
        let all = entries()
        for entry in all where entry.video.streamURL == remote {
            try? FileManager.default.removeItem(at: file(for: entry.video))
        }
        if let data = try? JSONEncoder().encode(all.filter { $0.video.streamURL != remote }) {
            try? data.write(to: manifest, options: .atomic)
        }
    }

    private func pruneFiles() {
        let keep = Set(entries().map { file(for: $0.video).lastPathComponent } + ["manifest.json"])
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func store(_ videos: [FeedVideo]) async {
        guard !isStoring, !Task.isCancelled else { return }
        isStoring = true
        pruneFiles()
        defer { isStoring = false; pruneFiles() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var saved: [Entry] = []
            for video in videos.prefix(2) {
                try Task.checkCancellation()
                guard video.streamURL.scheme?.lowercased() == "https" else { continue }
                if let existing = entries().first(where: { $0.video.streamURL == video.streamURL && $0.video.id == video.id }) {
                    saved.append(Entry(video: video, savedAt: existing.savedAt))
                    continue
                }
                do {
                    var request = URLRequest(url: video.streamURL)
                    request.timeoutInterval = 30
                    request.networkServiceType = .background
                    request.allowsConstrainedNetworkAccess = false
                    let (temporary, response) = try await download(request, maxFileBytes)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          ["video/mp4", "video/quicktime"].contains(http.mimeType?.lowercased() ?? "")
                            || ["mp4", "mov"].contains(video.streamURL.pathExtension.lowercased()),
                          fileSize(temporary) > 0, fileSize(temporary) <= maxFileBytes,
                          await validate(temporary) else {
                        await AppLog.debug("startup.cache", "download rejected bytes=\(fileSize(temporary)) mime=\(response.mimeType ?? "unknown")")
                        continue
                    }
                    await AppLog.info("startup.cache", "download validated bytes=\(fileSize(temporary))")
                    // Publish only complete, playable files; playlists are not accepted as video files.
                    let target = file(for: video)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    saved.append(Entry(video: video, savedAt: Date()))
                } catch {
                    await AppLog.debug("startup.cache", "clip cache skipped: \(error.localizedDescription)")
                }
            }
            guard !saved.isEmpty else { return }
            try JSONEncoder().encode(saved).write(to: manifest, options: .atomic)
            let keep = Set(saved.map { file(for: $0.video).lastPathComponent } + ["manifest.json"])
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where !keep.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
            await AppLog.info("startup.cache", "saved clips=\(saved.count)")
        } catch {
            await AppLog.debug("startup.cache", "cache fill skipped: \(error.localizedDescription)")
        }
    }
}

/// Owns a serial URLSession delegate so size limits are enforced during transfer.
private final class FeedCacheDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    nonisolated let maxBytes: Int64
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    nonisolated(unsafe) private var session: URLSession?
    nonisolated(unsafe) private var cancelled = false

    nonisolated init(maxBytes: Int64) { self.maxBytes = maxBytes }

    nonisolated static func download(_ request: URLRequest, limit: Int64) async throws -> (URL, URLResponse) {
        let driver = FeedCacheDownloader(maxBytes: limit)
        return try await withTaskCancellationHandler {
            try await driver.run(request)
        } onCancel: {
            driver.cancel()
        }
    }

    nonisolated private func run(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: request)
            task.priority = URLSessionTask.lowPriority
            lock.unlock()
            task.resume()
        }
    }

    nonisolated private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(URLError(.cancelled)))
    }

    nonisolated private func finish(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        if let continuation {
            continuation.resume(with: result)
        } else if case .success(let (url, _)) = result {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        // AVFoundation should inspect a video file, not an extensionless URLSession temp file.
        let target = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            finish(.success((target, response)))
        } catch { finish(.failure(error)) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
