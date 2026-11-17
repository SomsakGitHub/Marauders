//
//  UploaderKit.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders
@testable import MaraudersAuth

/// A `BackgroundClipUploader` with everything around it made for a test: a throwaway folder that holds the store's
/// directory and the clips, a stager whose free-space figure the test sets, a fake session, a saved session as the token
/// store, a refresher, a fake resolver, a log of reported tokens and a clock the test moves.
///
/// Call `cleanUp()` when the test ends; nothing touches the app's real `Application Support/PendingUpload`.
///
/// nonisolated: the uploader reads the clock and the free-space figure from its own actor while the test sets them,
/// which the lock makes safe.
nonisolated final class UploaderKit: @unchecked Sendable {
    /// A token of `user-1` that stays valid for an hour.
    static func validToken(subject: String = "user-1") -> String {
        TestAccessToken.make(subject: subject, expiresIn: 3_600)
    }

    /// A token of `user-1` that expired a minute ago.
    static func expiredToken(subject: String = "user-1") -> String {
        TestAccessToken.make(subject: subject, expiresIn: -60)
    }

    /// The body of the Worker's answer to an upload that stored the clip `id`.
    static func answer(id: UUID = UUID(), streamURL: String = "https://cdn.example.com/v/new.mp4") -> Data {
        let payload: [String: Any] = ["item": ["id": id.uuidString, "streamURL": streamURL]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// The clip the Worker's answer `answer(id:)` holds.
    static func item(id: UUID = UUID()) -> FeedVideo {
        try! VideoUploadForm.decodeItem(from: answer(id: id))
    }

    let folder: URL
    let store: UploadRecordStore
    let stager: UploadBodyStager
    let session = FakeBackgroundUploadSession()
    let tokens: SignOutSessionStorage
    let refresher: any TokenRefreshing
    let resolver = FakeStoredUploadResolver()
    let uploader: BackgroundClipUploader

    private let lock = NSLock()
    private var storedFreeBytes: Int64
    private var storedNow: Date
    private var storedReports: [String] = []

    init(
        token: String? = UploaderKit.validToken(),
        refresher: any TokenRefreshing = ScriptedRefresher(),
        freeBytes: Int64 = .max,
        policy: UploadPolicy = .standard,
        isAppActive: @escaping @Sendable () async -> Bool = { true }
    ) {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "uploader-kit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = UploadRecordStore(directory: folder.appending(path: "PendingUpload", directoryHint: .isDirectory))
        tokens = SignOutSessionStorage(userID: "user-1", accessToken: token)
        self.refresher = refresher
        storedFreeBytes = freeBytes
        storedNow = Date()

        // The closures reach the kit through a box, because the kit is not whole yet when they are made.
        let box = KitBox()
        stager = UploadBodyStager(store: store, availableBytes: { _ in box.kit?.freeBytes ?? 0 })
        uploader = BackgroundClipUploader(
            store: store, stager: stager, session: session, accessTokens: tokens, refresher: refresher,
            resolver: resolver, policy: policy, now: { box.kit?.now ?? Date() }, isAppActive: isAppActive)
        box.kit = self
    }

    /// The free space the stager is told the phone has.
    var freeBytes: Int64 {
        get { lock.withLock { storedFreeBytes } }
        set { lock.withLock { storedFreeBytes = newValue } }
    }

    /// The uploader's clock.
    var now: Date {
        get { lock.withLock { storedNow } }
        set { lock.withLock { storedNow = newValue } }
    }

    /// Every access token the uploader reported as rejected for good, in order. Empty until `listenForRejections()`.
    var reports: [String] { lock.withLock { storedReports } }

    /// Gives the uploader a reporter that notes into `reports`.
    func listenForRejections() async {
        await uploader.setRejectionReporter { [weak self] token in
            self?.lock.withLock { self?.storedReports.append(token) }
        }
    }

    /// A request for a fresh `.mp4` of `byteCount` bytes in the kit's folder (never in the store's directory).
    @MainActor
    func request(byteCount: Int = 1_000, mimeType: String = "video/mp4") throws -> ClipUploadRequest {
        let clip = folder.appending(path: "clip-\(UUID().uuidString).mp4")
        try Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: clip)
        return ClipUploadRequest(
            fileURL: clip, mimeType: mimeType, clipLocation: ClipLocation(latitude: 13.7563, longitude: 100.5018)!,
            caption: "Sunset over Bangkok", audioAssessment: nil)
    }

    /// Saves a record of `user-1` in `state` straight into the store, with a body file of its own unless `withBody` is
    /// false, and returns it.
    @discardableResult
    func record(
        id: UUID = UUID(),
        state: UploadRecordState = .uploading(fraction: 0, refreshedOnce: false),
        createdAt: Date? = nil,
        withBody: Bool = true
    ) throws -> UploadRecord {
        try store.prepareDirectory()
        let record = UploadRecord(
            version: UploadRecord.currentVersion, id: id, accountSubject: "user-1",
            bodyFileName: store.bodyURL(id: id).lastPathComponent, boundary: "marauders.boundary.\(UUID().uuidString)",
            byteCount: 2_048, createdAt: createdAt ?? now, state: state)
        try store.save(record)
        if withBody {
            try Data(repeating: 0xCD, count: 2_048).write(to: store.bodyURL(id: id))
        }
        return record
    }

    /// The names of the files in the store's directory; none when the directory does not exist.
    var storedFileNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Waits, a few seconds at most, until `condition` holds.
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Gives what is already on its way (a snapshot in a stream, say) the time to arrive, before a test checks that
    /// nothing came.
    static func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// Lets the closures an `UploaderKit` hands its uploader reach the kit once it exists.
private nonisolated final class KitBox: @unchecked Sendable {
    weak var kit: UploaderKit?
}

/// A `StoredUploadResolving` that answers with a clip a test sets, or throws, and notes every question.
nonisolated final class FakeStoredUploadResolver: StoredUploadResolving, @unchecked Sendable {
    struct Question: Equatable, Sendable {
        let key: UUID
        let accessToken: String
    }

    struct NothingStored: Error {}

    private let lock = NSLock()
    private var storedAnswer: FeedVideo?
    private var storedQuestions: [Question] = []

    /// The clip the resolver answers with; nil makes it throw `NothingStored`.
    var answer: FeedVideo? {
        get { lock.withLock { storedAnswer } }
        set { lock.withLock { storedAnswer = newValue } }
    }

    var questions: [Question] { lock.withLock { storedQuestions } }

    func storedClip(forKey key: UUID, accessToken: String) async throws -> FeedVideo {
        let answer = lock.withLock {
            storedQuestions.append(Question(key: key, accessToken: accessToken))
            return storedAnswer
        }
        guard let answer else { throw NothingStored() }
        return answer
    }
}

/// A `TokenRefreshing` that notes the token it is asked about, then holds its answer until the test opens its gate, so
/// a test can change the world while the refresh is out.
///
/// nonisolated: the uploader asks from its own actor while the test reads `asked`, which the lock makes safe.
nonisolated final class GatedRefresher: TokenRefreshing, @unchecked Sendable {
    let gate = SignOutGate()
    private let outcome: TokenRefreshOutcome
    private let lock = NSLock()
    private var rejectedTokens: [String] = []

    init(answering outcome: TokenRefreshOutcome) {
        self.outcome = outcome
    }

    /// The rejected access token of every question, in order; noted before the refresher waits.
    var asked: [String] { lock.withLock { rejectedTokens } }

    func refreshedAccessToken(replacing rejectedAccessToken: String) async -> TokenRefreshOutcome {
        lock.withLock { rejectedTokens.append(rejectedAccessToken) }
        await gate.wait()
        return outcome
    }
}

/// Collects every snapshot a stream gives, from a task of its own, until the stream ends or the probe is dropped.
nonisolated final class SnapshotProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [UploadSnapshot] = []
    private var reader: Task<Void, Never>?

    init(_ stream: AsyncStream<UploadSnapshot>) {
        reader = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.lock.withLock { self.collected.append(snapshot) }
            }
        }
    }

    deinit {
        reader?.cancel()
    }

    var values: [UploadSnapshot] { lock.withLock { collected } }

    /// Waits until the probe has collected `count` snapshots or more, and returns what it has.
    @discardableResult
    func waitForCount(_ count: Int) async -> [UploadSnapshot] {
        await UploaderKit.waitUntil { values.count >= count }
        return values
    }
}
