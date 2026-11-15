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
    private func cache(
        _ directory: URL, limit: Int64 = 1024, lifetime: TimeInterval = 3600,
        body: Data = Data([1, 2, 3]), status: Int = 200
    ) -> FeedStartupCache {
        FeedStartupCache(
            directory: directory,
            download: { request, _ in
                let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try body.write(to: temporary)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "video/mp4"])!
                return (temporary, response)
            }, maxFileBytes: limit, lifetime: lifetime,
            validate: { url in
                (try? Data(contentsOf: url)) == Data([1, 2, 3])
            })
    }

    @Test func sessionCacheSeparatesAccountsAndSurvivesReopen() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var token: String? = "account-a-session"
        let scoped = SessionFeedStartupCache(
            directory: directory, tokenProvider: { token },
            makeCache: { cache($0) })
        let video = clip(1)
        await scoped.store([video])
        #expect(await scoped.cachedVideos() == [video])
        token = "account-b-session"
        #expect(await scoped.cachedVideos().isEmpty)
        #expect(await scoped.localURL(for: video.streamURL) == nil)
        token = nil
        #expect(await scoped.cachedVideos().isEmpty)
        token = "account-a-session"
        let reopened = SessionFeedStartupCache(
            directory: directory, tokenProvider: { token },
            makeCache: { cache($0) })
        #expect(await reopened.cachedVideos() == [video])
        let paths = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(paths.allSatisfy { !$0.contains("account-a-session") })
    }

    /// The access token the app holds, which a test replaces the way a refresh, a sign-in or a sign-out would.
    @MainActor private final class StoredToken {
        var value: String?
        init(_ value: String? = nil) { self.value = value }
    }

    private func sessionCache(_ directory: URL, token: StoredToken) -> SessionFeedStartupCache {
        SessionFeedStartupCache(directory: directory, tokenProvider: { token.value }, makeCache: { cache($0) })
    }

    @Test func twoTokensOfOneAccountShareACache() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A refresh gives the same account a different token string; it is still the same viewer.
        let issued = TestAccessToken.make(subject: "account-a", expiresIn: 3600)
        let refreshed = TestAccessToken.make(subject: "account-a", expiresIn: 7200)
        let afterRelaunch = TestAccessToken.make(subject: "account-a", expiresIn: 10_800)
        #expect(Set([issued, refreshed, afterRelaunch]).count == 3, "three different token strings")
        let token = StoredToken(issued)
        let scoped = sessionCache(directory, token: token)
        let video = clip(1)
        await scoped.store([video])

        token.value = refreshed
        #expect(await scoped.cachedVideos() == [video])
        #expect(await scoped.localURL(for: video.streamURL) != nil)

        token.value = afterRelaunch
        let reopened = sessionCache(directory, token: token)
        #expect(await reopened.cachedVideos() == [video])
        let folders = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(folders.count == 1, "one folder for the account, not one per token")
    }

    @Test func anotherAccountGetsItsOwnCache() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = StoredToken(TestAccessToken.make(subject: "account-a", expiresIn: 3600))
        let scoped = sessionCache(directory, token: token)
        let mine = clip(1)
        let theirs = clip(2)
        await scoped.store([mine])

        token.value = TestAccessToken.make(subject: "account-b", expiresIn: 3600)
        #expect(await scoped.cachedVideos().isEmpty)
        #expect(await scoped.localURL(for: mine.streamURL) == nil)
        await scoped.store([theirs])
        #expect(await scoped.cachedVideos() == [theirs])

        // The first account again, on a token the refresh issued since.
        token.value = TestAccessToken.make(subject: "account-a", expiresIn: 7200)
        #expect(await scoped.cachedVideos() == [mine])
        #expect(await scoped.localURL(for: theirs.streamURL) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func aGuestHasItsOwnCache() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = StoredToken()
        let scoped = sessionCache(directory, token: token)
        let guestClip = clip(1)
        let memberClip = clip(2)
        await scoped.store([guestClip])
        #expect(await scoped.cachedVideos() == [guestClip])

        token.value = TestAccessToken.make(subject: "account-a", expiresIn: 3600)
        #expect(await scoped.cachedVideos().isEmpty, "signing in does not inherit the guest's clips")
        await scoped.store([memberClip])

        token.value = nil
        #expect(await scoped.cachedVideos() == [guestClip], "a guest finds the guest's clips, not the account's")
    }

    @Test func aTokenWithoutAReadableSubjectStillGetsItsOwnCache() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        // None of these names an account, so each is kept apart by the token itself. Sharing one folder between them
        // would show one account's clips to another.
        let tokens = [
            "opaque-one",
            "opaque-two",
            TestAccessToken.make(claims: ["iat": 1]),
            TestAccessToken.make(claims: ["iat": 2]),
            TestAccessToken.make(claims: ["sub": "", "iat": 1]),
            TestAccessToken.make(claims: ["sub": 7, "iat": 1]),
        ]
        let token = StoredToken()
        let scoped = sessionCache(directory, token: token)
        var stored: [FeedVideo] = []
        for (index, candidate) in tokens.enumerated() {
            token.value = candidate
            let video = clip(index)
            stored.append(video)
            #expect(await scoped.cachedVideos().isEmpty, "token \(index) sees nobody else's clips")
            await scoped.store([video])
        }
        for (index, candidate) in tokens.enumerated() {
            token.value = candidate
            #expect(await scoped.cachedVideos() == [stored[index]], "token \(index) finds its own clips again")
        }
    }

    @Test func folderNamesDoNotRevealTheAccountOrTheToken() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountToken = TestAccessToken.make(subject: "account-a", expiresIn: 3600)
        let scoped = sessionCache(directory, token: StoredToken(accountToken))
        await scoped.store([clip(1)])

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 1)
        for name in names {
            let isDigest = name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            #expect(isDigest, "a SHA-256 digest in lowercase hex: \(name)")
            #expect(!name.contains("account-a"))
        }
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
        for (limit, body, status) in [
            (Int64(2), Data([1, 2, 3]), 200),
            (Int64(1024), Data([9]), 200),
            (Int64(1024), Data([1, 2, 3]), 503),
        ] {
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
