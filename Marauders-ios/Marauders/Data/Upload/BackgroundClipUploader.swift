//
//  BackgroundClipUploader.swift
//  Marauders
//

import Foundation

/// The rules a background upload follows.
nonisolated struct UploadPolicy: Sendable {
    /// How long a record is kept after its `createdAt`: 7 days.
    var maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Whether a 401 healed while the app is not active sends the body again at once. Off: on the spike, a task created
    /// from a background wake did not start until the app was active again (223 s later), so it fails as interrupted
    /// and the viewer tries again.
    var resubmitsWhileInBackground = false
    /// How much of the Worker's answer is kept per upload.
    var responseBodyLimit = 65_536

    static let standard = UploadPolicy()
}

/// Asks the Worker for the clip it stored under an upload's idempotency key, for a success whose answer never reached
/// the app.
nonisolated protocol StoredUploadResolving: Sendable {
    func storedClip(forKey key: UUID, accessToken: String) async throws -> FeedVideo
}

/// Uploads the viewer's clip through a background session, so the upload goes on when the viewer leaves the app and
/// ends even if the app is not running.
///
/// One upload at a time. `start` stages the body and a record on disk (`UploadRecordStore`), submits one task and
/// returns; from then on the session's events move the record along, and every change is published as an
/// `UploadSnapshot`. The record is the truth: after every `await` in a change of state the uploader reads it again,
/// and an event for a record that is gone, or no longer in a state that takes it, is ignored and recreates nothing.
///
/// It never signs anyone out and never clears a token store: a token rejected for good is reported through the
/// rejection reporter, when one is set.
actor BackgroundClipUploader {
    let store: UploadRecordStore
    let stager: UploadBodyStager
    let session: any BackgroundUploadSession
    let accessTokens: any APIAccessTokenStore
    let refresher: any TokenRefreshing
    let resolver: any StoredUploadResolving
    let policy: UploadPolicy
    let now: @Sendable () -> Date
    let isAppActive: @Sendable () async -> Bool

    /// Told the access token a 401 rejected for good. None until the container sets one.
    var rejectionReporter: (@Sendable (String) async -> Void)?
    /// A `start` is running: it refuses a second one, and reconcile leaves the body it may be staging alone.
    var isStarting = false
    /// Moved by every `discard()`, so a `start` or a retry that was waiting can tell it was discarded meanwhile.
    var discardCount = 0
    /// The Worker's answer so far, per record, up to `policy.responseBodyLimit` bytes.
    var responseBodies: [UUID: Data] = [:]
    /// Everyone reading `snapshots()`.
    var observers: [UUID: AsyncStream<UploadSnapshot>.Continuation] = [:]

    init(
        store: UploadRecordStore,
        stager: UploadBodyStager,
        session: any BackgroundUploadSession,
        accessTokens: any APIAccessTokenStore,
        refresher: any TokenRefreshing,
        resolver: any StoredUploadResolving,
        policy: UploadPolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        isAppActive: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.store = store
        self.stager = stager
        self.session = session
        self.accessTokens = accessTokens
        self.refresher = refresher
        self.resolver = resolver
        self.policy = policy
        self.now = now
        self.isAppActive = isAppActive
    }

    func setRejectionReporter(_ report: @escaping @Sendable (String) async -> Void) {
        rejectionReporter = report
    }

    // MARK: Start

    /// Takes the clip over: stages its body and a record, submits one task and publishes `.uploading(fraction: 0)`.
    /// Returns once the task is submitted, long before the Worker answers.
    ///
    /// - Throws: `ClipUploadError.alreadyUploading` while another start runs or an upload is staged or on its way;
    ///   `VideoUploadAPIError` for a clip that cannot go out or no usable token; `SessionRefreshUnavailableError`
    ///   when an expired token could not be traded; `ClipUploadError.notEnoughSpace`; `ClipUploadError.unavailable`
    ///   when the upload was discarded while it was starting. Nothing is left on disk after a throw.
    func start(_ request: ClipUploadRequest) async throws {
        guard !isStarting else { throw ClipUploadError.alreadyUploading }
        let existing = store.records()
        for record in existing {
            switch record.state {
            case .staged, .uploading: throw ClipUploadError.alreadyUploading
            case .finished, .failed: break
            }
        }
        // A finished or failed upload's task is over, so there is nothing to cancel: the next clip takes its slot.
        for record in existing {
            store.delete(id: record.id)
            responseBodies[record.id] = nil
        }

        isStarting = true
        defer { isStarting = false }
        let discards = discardCount

        let clipByteCount = try VideoUploadForm.validatedSize(of: request.fileURL, mimeType: request.mimeType)

        var token = try await usableAccessToken()
        if APIAccessTokenExpiry.isExpired(token, now: now()) {
            let outcome = await refresher.refreshedAccessToken(replacing: token)
            guard discardCount == discards else { throw ClipUploadError.unavailable }
            switch outcome {
            case .refreshed(let newToken):
                token = newToken
            case .rejected:
                await rejectionReporter?(token)
                throw VideoUploadAPIError.notAuthenticated
            case .unavailable:
                throw SessionRefreshUnavailableError()
            }
        }
        guard APIAccessTokenFormat.isValid(token), let subject = APIAccessTokenSubject.subject(of: token) else {
            throw VideoUploadAPIError.notAuthenticated
        }

        // A misconfiguration fails here, before a file exists.
        _ = try await APIConfiguration.videoUploadURL()

        let id = UUID()
        let parts = VideoUploadForm.parts(
            fileURL: request.fileURL, mimeType: request.mimeType, clipLocation: request.clipLocation,
            caption: request.caption, audioAssessment: request.audioAssessment)
        let staged = try await stager.stage(id: id, parts: parts, clipByteCount: clipByteCount)
        guard discardCount == discards else {
            store.deleteBody(id: id)
            throw ClipUploadError.unavailable
        }

        var record = UploadRecord(
            version: UploadRecord.currentVersion, id: id, accountSubject: subject,
            bodyFileName: store.bodyURL(id: id).lastPathComponent, boundary: staged.boundary,
            byteCount: staged.byteCount, createdAt: now(), state: .staged)
        do {
            try store.save(record)
        } catch {
            store.deleteBody(id: id)
            throw error
        }

        let uploadRequest: URLRequest
        do {
            uploadRequest = try await VideoUploadForm.request(
                authorizationHeader: "Bearer " + token, boundary: staged.boundary, idempotencyKey: id)
        } catch {
            store.delete(id: id)
            throw error
        }
        guard discardCount == discards else {
            store.delete(id: id)
            throw ClipUploadError.unavailable
        }

        session.submit(uploadRequest, bodyFile: store.bodyURL(id: id), recordID: id, expectedBytes: staged.byteCount)
        record.state = .uploading(fraction: 0, refreshedOnce: false)
        let saved = (try? store.save(record)) != nil
        publish(record.snapshot)

        // A record left `staged` is put right by reconcile, which finds its task.
        await AppLog.info("upload.bg", "\(Self.shortID(id)) \(saved ? "uploading" : "submitted, record still staged")")
    }

    /// The stored access token, when it is one: well formed and naming its account.
    private func usableAccessToken() async throws -> String {
        let accessTokens = accessTokens
        let stored = await MainActor.run { accessTokens.loadAccessToken() }
        guard let stored, APIAccessTokenFormat.isValid(stored), APIAccessTokenSubject.subject(of: stored) != nil else {
            throw VideoUploadAPIError.notAuthenticated
        }
        return stored
    }

    // MARK: Snapshots

    /// The current snapshot first, then every change, until the reader stops reading.
    func snapshots() -> AsyncStream<UploadSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: UploadSnapshot.self)
        let key = UUID()
        observers[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key) }
        }
        continuation.yield(store.records().first?.snapshot ?? .idle)
        return stream
    }

    private func removeObserver(_ key: UUID) {
        observers[key] = nil
    }

    func publish(_ snapshot: UploadSnapshot) {
        for observer in observers.values {
            observer.yield(snapshot)
        }
    }

    // MARK: Discard

    /// Drops the upload, whatever it is doing: deletes its record and body, publishes `.idle` and cancels its task.
    /// A `start` that is under way notices and leaves nothing behind.
    func discard() async {
        discardCount += 1
        let records = store.records()
        for record in records {
            store.delete(id: record.id)
        }
        responseBodies = [:]
        publish(.idle)
        for record in records {
            await session.cancel(recordID: record.id)
            await AppLog.info("upload.bg", "\(Self.shortID(record.id)) discarded")
        }
    }

    // MARK: Events

    /// Moves the record of the event along. An event for a record that is gone, or not in a state that takes it, is
    /// ignored.
    func apply(_ event: UploadSessionEvent) async {
        switch event {
        case .sentBytes(let recordID, let sent, let expected):
            applyProgress(recordID: recordID, sent: sent, expected: expected)
        case .receivedBody(let recordID, let data):
            bufferResponse(recordID: recordID, data: data)
        case .completed(let recordID, let statusCode, let failure, let accessToken):
            await complete(recordID: recordID, statusCode: statusCode, failure: failure, accessToken: accessToken)
        case .eventsFinished:
            // Task 7
            break
        }
    }

    /// Saves and publishes the share sent, only when its whole percent changes. Every byte sent is `finishing`.
    private func applyProgress(recordID: UUID, sent: Int64, expected: Int64) {
        guard expected > 0, var record = record(recordID),
            case .uploading(let fraction, let refreshedOnce) = record.state
        else { return }
        let newFraction = min(max(Double(sent) / Double(expected), 0), 1)
        guard Int(newFraction * 100) != Int(fraction * 100) else { return }
        record.state = .uploading(fraction: newFraction, refreshedOnce: refreshedOnce)
        try? store.save(record)
        publish(record.snapshot)
    }

    private func bufferResponse(recordID: UUID, data: Data) {
        guard let record = record(recordID), Self.takesCompletion(record.state) else { return }
        var body = responseBodies[recordID] ?? Data()
        body.append(data.prefix(max(policy.responseBodyLimit - body.count, 0)))
        responseBodies[recordID] = body
    }

    /// Settles a success: the record becomes `finished` with the clip, and its body is deleted. A record that is gone
    /// or already settled otherwise keeps its verdict.
    func finish(recordID: UUID, with item: FeedVideo) async {
        responseBodies[recordID] = nil
        guard var record = record(recordID), Self.takesCompletion(record.state) else { return }
        record.state = .finished(item)
        do {
            try store.save(record)
        } catch {
            await AppLog.warning("upload.bg", "\(Self.shortID(recordID)) finished, record not saved")
            return
        }
        store.deleteBody(id: recordID)
        publish(record.snapshot)
        await AppLog.info("upload.bg", "\(Self.shortID(recordID)) finished")
    }

    /// Whether a record in `state` still takes the end of its task: one on its way, one whose task a relaunch found
    /// before reconcile marked it, and one judged interrupted, which a real answer overrules.
    static func takesCompletion(_ state: UploadRecordState) -> Bool {
        switch state {
        case .staged, .uploading, .failed(.interrupted): true
        case .finished, .failed: false
        }
    }

    func record(_ id: UUID) -> UploadRecord? {
        store.records().first { $0.id == id }
    }

    /// The first 8 characters of the id, which is all a log line names.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}
