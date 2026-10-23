import Foundation
import Testing
@testable import Marauders

@MainActor
struct FeedStartupCacheTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
    private func clip(_ index: Int) -> FeedVideo {
        FeedVideo(streamURL: URL(string: "https://example.com/\(index).mp4")!, caption: "clip \(index)")
    }
    private func cache(_ directory: URL, limit: Int64 = 1024, lifetime: TimeInterval = 3600,
                       body: Data = Data([1, 2, 3]), status: Int = 200) -> FeedStartupCache {
        FeedStartupCache(directory: directory, download: { request, _ in
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try body.write(to: temporary)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "video/mp4"])!
            return (temporary, response)
        }, maxFileBytes: limit, lifetime: lifetime, validate: { url in
            (try? Data(contentsOf: url)) == Data([1, 2, 3])
        })
    }

    @Test func persistsCompleteVideosAcrossCacheInstancesAndCapsCount() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clips = [clip(1), clip(2), clip(3)]
        await cache(directory).store(clips)
        let reopened = cache(directory)
        #expect(await reopened.cachedVideos() == Array(clips.prefix(2)))
        let local = try #require(await reopened.localURL(for: clips[0].streamURL))
        #expect(local.isFileURL)
        #expect(try Data(contentsOf: local) == Data([1, 2, 3]))
        #expect(await reopened.localURL(for: clips[2].streamURL) == nil)
    }

    @Test func expiredOrMissingFilesDoNotRestore() async {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = clip(1)
        await cache(directory).store([video])
        #expect(await cache(directory, lifetime: -1).cachedVideos().isEmpty)
        try? FileManager.default.removeItem(at: directory.appending(path: video.id.uuidString + ".mp4"))
        #expect(await cache(directory).cachedVideos().isEmpty)
    }

    @Test func rejectsOversizedIncompleteAndHTTPErrorDownloads() async {
        for (limit, body, status) in [(Int64(2), Data([1, 2, 3]), 200),
                                     (Int64(1024), Data([9]), 200),
                                     (Int64(1024), Data([1, 2, 3]), 503)] {
            let directory = folder()
            await cache(directory, limit: limit, body: body, status: status).store([clip(1)])
            #expect(await cache(directory).cachedVideos().isEmpty)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func damagedFileIsDiscardedAndCanFallBackToRemote() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = clip(1)
        let store = cache(directory)
        await store.store([video])
        let local = try #require(await store.localURL(for: video.streamURL))
        try Data([9]).write(to: local)
        #expect(await cache(directory).cachedVideos().isEmpty)
        #expect(await store.localURL(for: video.streamURL) == nil)
    }

    @Test func replacementPrunesOldFilesAndInvalidationPreservesOtherClip() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = clip(1)
        let next = [clip(2), clip(3)]
        let store = cache(directory)
        await store.store([old])
        await store.store(next)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: old.id.uuidString + ".mp4").path))
        await store.invalidate(next[0].streamURL)
        #expect(await store.cachedVideos() == [next[1]])
    }
}
