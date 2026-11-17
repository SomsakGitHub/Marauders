//
//  BackgroundClipUploaderLaunchTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders
@testable import MaraudersAuth

/// What `BackgroundClipUploader` does at launch with the upload left on disk (`reconcile`), the viewer's Try again
/// (`retry`), the ordered pump `launch` starts, and the latch the scene waits on (`awaitSystemEvents`). Records are
/// written straight into the kit's store; the kit's clock is moved, never slept.
struct BackgroundClipUploaderLaunchTests {
    /// A second token of `user-1`, other than the kit's, as a refresh hands out.
    private static let newToken = TestAccessToken.make(subject: "user-1", expiresIn: 7_200)

    private static func failed(_ failure: UploadFailure) -> UploadSnapshot {
        .failed(message: failure.message, canRetry: failure.canRetry)
    }

    /// A probe that has already received the uploader's current snapshot.
    private static func probe(_ kit: UploaderKit) async -> SnapshotProbe {
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)
        return probe
    }

    /// The snapshot the probe received last, once what was on its way has arrived.
    private static func lastSnapshot(_ probe: SnapshotProbe) async -> UploadSnapshot? {
        await UploaderKit.settle()
        return probe.values.last
    }

    // MARK: Reconcile: accounts, age and orphans

    @Test func aRecordOfAnotherAccountIsDeletedAtLaunch() async throws {
        let kit = UploaderKit(token: UploaderKit.validToken(subject: "user-2"))
        defer { kit.cleanUp() }
        let record = try kit.record()
        kit.session.pending = [record.id]
        let probe = await Self.probe(kit)

        await kit.uploader.launch()

        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.session.cancelled == [record.id])
        #expect(kit.session.submissions.isEmpty)
        #expect(await Self.lastSnapshot(probe) == .idle)
    }

    @Test func anUnreadableSubjectCountsAsAnotherAccount() async throws {
        let withoutSubject = TestAccessToken.make(claims: ["exp": Int(Date().timeIntervalSince1970) + 3_600])
        let kit = UploaderKit(token: withoutSubject)
        defer { kit.cleanUp() }
        let record = try kit.record()
        kit.session.pending = [record.id]
        let probe = await Self.probe(kit)

        await kit.uploader.launch()

        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.session.cancelled == [record.id])
        #expect(await Self.lastSnapshot(probe) == .idle)
    }

    @Test func withNoTokenStoredTheRecordIsKept() async throws {
        let kit = UploaderKit(token: nil)
        defer { kit.cleanUp() }
        let record = try kit.record(state: .uploading(fraction: 0.4, refreshedOnce: false))
        kit.session.pending = [record.id]

        await kit.uploader.launch()

        #expect(kit.store.records() == [record])
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.cancelled.isEmpty)
    }

    @Test func aRecordOfTheSameAccountIsKept() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .uploading(fraction: 0.4, refreshedOnce: false))
        kit.session.pending = [record.id]

        await kit.uploader.launch()

        #expect(kit.store.records() == [record])
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.cancelled.isEmpty)
    }

    /// 7 days and one second, and 6 days and 23 hours.
    private static let ages: [(TimeInterval, Bool)] = [(604_801, true), (601_200, false)]

    @Test(arguments: ages)
    func anOldRecordIsDeletedWithItsBody(_ age: TimeInterval, _ isDeleted: Bool) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))
        kit.now = record.createdAt.addingTimeInterval(age)
        let probe = await Self.probe(kit)

        await kit.uploader.reconcile()

        if isDeleted {
            #expect(kit.store.records().isEmpty)
            #expect(kit.storedFileNames.isEmpty)
            #expect(kit.session.cancelled == [record.id])
            #expect(await Self.lastSnapshot(probe) == .idle)
        } else {
            #expect(kit.store.records() == [record])
            #expect(kit.store.bodyExists(id: record.id))
            #expect(kit.session.cancelled.isEmpty)
            #expect(await Self.lastSnapshot(probe) == Self.failed(.interrupted))
        }
    }

    @Test func anOrphanBodyIsDeletedAtLaunch() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))
        let orphan = UUID()
        try Data(repeating: 0xAB, count: 64).write(to: kit.store.bodyURL(id: orphan))

        await kit.uploader.launch()

        #expect(!kit.store.bodyExists(id: orphan))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.store.records() == [record])
    }

    // MARK: Reconcile: by state

    @Test func aStagedRecordWithNoTaskIsSubmittedAtLaunch() async throws {
        let token = UploaderKit.validToken()
        let kit = UploaderKit(token: token)
        defer { kit.cleanUp() }
        let record = try kit.record(state: .staged)
        let probe = await Self.probe(kit)

        await kit.uploader.launch()

        let submission = try #require(kit.session.submissions.first)
        #expect(kit.session.submissions.count == 1)
        #expect(submission.recordID == record.id)
        #expect(submission.bodyFile == kit.store.bodyURL(id: record.id))
        #expect(submission.expectedBytes == record.byteCount)
        #expect(submission.request.value(forHTTPHeaderField: "Idempotency-Key") == record.id.uuidString.lowercased())
        #expect(
            submission.request.value(forHTTPHeaderField: "Content-Type")
                == "multipart/form-data; boundary=\(record.boundary)")
        #expect(submission.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
        #expect(await Self.lastSnapshot(probe) == .uploading(fraction: 0))
    }

    @Test func aStagedRecordWhoseTaskExistsIsNotSubmittedAgain() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .staged)
        kit.session.pending = [record.id]

        await kit.uploader.launch()

        #expect(kit.session.submissions.isEmpty)
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test func anUploadingRecordWithNoTaskBecomesInterrupted() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .uploading(fraction: 0.4, refreshedOnce: false))
        let probe = await Self.probe(kit)

        await kit.uploader.launch()

        #expect(kit.store.records().first?.state == .failed(.interrupted))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.submissions.isEmpty)
        #expect(
            await Self.lastSnapshot(probe)
                == .failed(message: "The upload was interrupted. Try again.", canRetry: true))
    }

    @Test func anUploadingRecordWhoseTaskExistsKeepsUploading() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .uploading(fraction: 0.4, refreshedOnce: true))
        kit.session.pending = [record.id]
        let probe = await Self.probe(kit)

        await kit.uploader.launch()

        #expect(kit.store.records() == [record])
        #expect(kit.session.submissions.isEmpty)
        #expect(await Self.lastSnapshot(probe) == .uploading(fraction: 0.4))
    }

    @Test(arguments: [UploadRecordState.staged, .uploading(fraction: 0.4, refreshedOnce: false)])
    func aMissingBodyBecomesBodyMissingAndCannotBeRetried(_ state: UploadRecordState) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        try kit.record(state: state, withBody: false)
        let probe = await Self.probe(kit)

        await kit.uploader.launch()
        await kit.uploader.retry()

        #expect(kit.store.records().first?.state == .failed(.bodyMissing))
        #expect(kit.session.submissions.isEmpty)
        #expect(
            await Self.lastSnapshot(probe)
                == .failed(message: "The clip is no longer on this iPhone. Choose the video again.", canRetry: false))
    }

    @Test(arguments: [UploadRecordState.finished(UploaderKit.item()), .failed(.responseLost)])
    func aFinishedRecordIsKeptUntilItIsShown(_ state: UploadRecordState) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: state, withBody: false)
        let probe = await Self.probe(kit)

        await kit.uploader.launch()

        #expect(kit.store.records() == [record])
        #expect(kit.session.submissions.isEmpty)
        #expect(kit.session.cancelled.isEmpty)
        #expect(await Self.lastSnapshot(probe) == record.snapshot)
    }

    // MARK: Reconcile against a start or a retry

    @Test(.timeLimit(.minutes(1))) func aReconcileWhileAStartIsRunningKeepsTheBodyItStages() async throws {
        let refresher = GatedRefresher(answering: .refreshed(UploaderKit.validToken()))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        let request = try await kit.request()
        let start = Task { try await kit.uploader.start(request) }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }
        // A body with no record yet, as the start's own is between being written and its record being saved.
        try kit.store.prepareDirectory()
        let staging = UUID()
        try Data(repeating: 0xAB, count: 64).write(to: kit.store.bodyURL(id: staging))

        await kit.uploader.reconcile()

        #expect(kit.store.bodyExists(id: staging))
        await refresher.gate.open()
        try await start.value
    }

    @Test(.timeLimit(.minutes(1))) func aReconcileWhileAStartIsRunningDoesNotSubmitItsStagedRecord() async throws {
        let refresher = GatedRefresher(answering: .refreshed(UploaderKit.validToken()))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        let request = try await kit.request()
        let start = Task { try await kit.uploader.start(request) }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }
        // Stands for the record the start saves as `staged` before it submits.
        let staged = try kit.record(state: .staged)

        await kit.uploader.reconcile()

        #expect(kit.session.submissions.isEmpty)
        #expect(kit.store.records().first { $0.id == staged.id } == staged)
        #expect(kit.store.bodyExists(id: staged.id))
        await refresher.gate.open()
        try await start.value
        #expect(!kit.session.submissions.map(\.recordID).contains(staged.id))
    }

    @Test(.timeLimit(.minutes(1))) func aReconcileWhileARetryWaitsLeavesTheStagedRecordAlone() async throws {
        let refresher = GatedRefresher(answering: .refreshed(Self.newToken))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))
        let retry = Task { await kit.uploader.retry() }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }

        await kit.uploader.reconcile()

        #expect(kit.session.submissions.isEmpty)
        #expect(kit.store.records().first?.state == .staged)
        #expect(kit.store.bodyExists(id: record.id))
        await refresher.gate.open()
        await retry.value
        #expect(kit.session.submissions.map(\.recordID) == [record.id])
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
    }

    // MARK: The pump

    @Test(.timeLimit(.minutes(1))) func launchStartsThePumpOnceAndAppliesEventsInOrder() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .uploading(fraction: 0, refreshedOnce: false))
        kit.session.pending = [record.id]
        let probe = await Self.probe(kit)
        let clipID = UUID()

        await kit.uploader.launch()
        await kit.uploader.launch()
        kit.session.emit(.sentBytes(recordID: record.id, sent: 50, expected: 100))
        kit.session.emit(.receivedBody(recordID: record.id, data: UploaderKit.answer(id: clipID)))
        kit.session.emit(
            .completed(recordID: record.id, statusCode: 201, failure: nil, accessToken: UploaderKit.validToken()))
        await UploaderKit.waitUntil { probe.values.last == .finished(UploaderKit.item(id: clipID)) }

        #expect(probe.values.suffix(2) == [.uploading(fraction: 0.5), .finished(UploaderKit.item(id: clipID))])
        #expect(kit.store.records().first?.state == .finished(UploaderKit.item(id: clipID)))
        #expect(!kit.store.bodyExists(id: record.id))
    }

    // MARK: Retry

    @Test func retryReusesTheRecordIdAsTheKeyAndSendsTheSameBody() async throws {
        let token = UploaderKit.validToken()
        let kit = UploaderKit(token: token)
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.responseLost))
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        let submission = try #require(kit.session.submissions.first)
        #expect(kit.session.submissions.count == 1)
        #expect(submission.recordID == record.id)
        #expect(submission.bodyFile == kit.store.bodyURL(id: record.id))
        #expect(submission.expectedBytes == record.byteCount)
        #expect(submission.request.value(forHTTPHeaderField: "Idempotency-Key") == record.id.uuidString.lowercased())
        #expect(
            submission.request.value(forHTTPHeaderField: "Content-Type")
                == "multipart/form-data; boundary=\(record.boundary)")
        #expect(submission.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(kit.store.records().map(\.id) == [record.id])
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(
            await probe.waitForCount(3)
                == [Self.failed(.responseLost), .uploading(fraction: 0), .uploading(fraction: 0)])
    }

    @Test func retryTradesAnExpiredTokenFirstAndResetsTheRefreshFlag() async throws {
        let old = UploaderKit.expiredToken()
        let refresher = ScriptedRefresher(.refreshed(Self.newToken))
        let kit = UploaderKit(token: old, refresher: refresher)
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))

        await kit.uploader.retry()

        #expect(refresher.asked == [old])
        let submission = try #require(kit.session.submissions.first)
        #expect(kit.session.submissions.count == 1)
        #expect(submission.recordID == record.id)
        #expect(submission.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.newToken)")
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
    }

    @Test(arguments: [
        UploadFailure.sessionEnded, .unavailable, .connection("The network connection was lost."), .rateLimited,
        .serverError("Upload failed (status 500)"), .interrupted, .responseLost,
    ])
    func aRetryFromEveryRetryableFailureSendsTheSameBodyAgain(_ failure: UploadFailure) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(failure))

        await kit.uploader.retry()

        #expect(kit.session.submissions.map(\.recordID) == [record.id])
        #expect(kit.session.submissions.first?.bodyFile == kit.store.bodyURL(id: record.id))
        #expect(
            kit.session.submissions.first?.request.value(forHTTPHeaderField: "Idempotency-Key")
                == record.id.uuidString.lowercased())
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
        #expect(kit.store.records().first?.snapshot == .uploading(fraction: 0))
    }

    @Test(.timeLimit(.minutes(1))) func aDiscardWhileRetryWaitsForTheRefreshSubmitsNothing() async throws {
        let refresher = GatedRefresher(answering: .refreshed(Self.newToken))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        try kit.record(state: .failed(.interrupted))
        let probe = await Self.probe(kit)

        let retry = Task { await kit.uploader.retry() }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }
        await kit.uploader.discard()
        await refresher.gate.open()
        await retry.value

        #expect(kit.session.submissions.isEmpty)
        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(await Self.lastSnapshot(probe) == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondRetryWhileTheFirstWaitsForTheRefreshSubmitsOnce() async throws {
        let refresher = GatedRefresher(answering: .refreshed(Self.newToken))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))

        let first = Task { await kit.uploader.retry() }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }
        let second = Task { await kit.uploader.retry() }
        await second.value
        await refresher.gate.open()
        await first.value

        #expect(kit.session.submissions.map(\.recordID) == [record.id])
        #expect(refresher.asked.count == 1)
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
    }

    @Test(arguments: [
        UploadRecordState.failed(.rejected("Clip too long")), .failed(.bodyMissing),
        .uploading(fraction: 0.4, refreshedOnce: false), .staged, .finished(UploaderKit.item()),
    ])
    func retryDoesNothingForAFailureThatCannotBeRetried(_ state: UploadRecordState) async throws {
        let refresher = ScriptedRefresher()
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        let record = try kit.record(state: state)
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        #expect(kit.store.records() == [record])
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.submissions.isEmpty)
        #expect(refresher.asked.isEmpty)
        await UploaderKit.settle()
        #expect(probe.values == [record.snapshot])
    }

    @Test func retryForAnotherAccountDeletesTheRecord() async throws {
        let kit = UploaderKit(token: UploaderKit.validToken(subject: "user-2"))
        defer { kit.cleanUp() }
        try kit.record(state: .failed(.interrupted))
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.session.submissions.isEmpty)
        #expect(await Self.lastSnapshot(probe) == .idle)
    }

    @Test func aRetryWhoseTaskIsStillAliveDoesNotSubmitAgain() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))
        kit.session.pending = [record.id]
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        #expect(kit.session.submissions.isEmpty)
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(await Self.lastSnapshot(probe) == .uploading(fraction: 0))
    }

    @Test func aRetryWithNoTokenFailsAsSessionEnded() async throws {
        let refresher = ScriptedRefresher()
        let kit = UploaderKit(token: nil, refresher: refresher)
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        #expect(kit.store.records().first?.state == .failed(.sessionEnded))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.submissions.isEmpty)
        #expect(refresher.asked.isEmpty)
        #expect(await Self.lastSnapshot(probe) == Self.failed(.sessionEnded))
    }

    @Test func aRetryWithARejectedTradeEndsTheSessionAndReportsTheOldToken() async throws {
        let old = UploaderKit.expiredToken()
        let kit = UploaderKit(token: old, refresher: ScriptedRefresher(.rejected))
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let record = try kit.record(state: .failed(.unavailable))
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        #expect(kit.store.records().first?.state == .failed(.sessionEnded))
        #expect(kit.reports == [old])
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.submissions.isEmpty)
        #expect(await Self.lastSnapshot(probe) == Self.failed(.sessionEnded))
    }

    @Test func anUnavailableTradeFailsTheRetryAsUnavailable() async throws {
        let refresher = ScriptedRefresher(.unavailable(URLError(.notConnectedToInternet)))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let record = try kit.record(state: .failed(.connection("The network connection was lost.")))
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        #expect(kit.store.records().first?.state == .failed(.unavailable))
        #expect(kit.reports.isEmpty)
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.submissions.isEmpty)
        #expect(await Self.lastSnapshot(probe) == Self.failed(.unavailable))
    }

    @Test func aRetryWithoutTheBodyFileFailsAsBodyMissing() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        try kit.record(state: .failed(.interrupted), withBody: false)
        let probe = await Self.probe(kit)

        await kit.uploader.retry()

        #expect(kit.store.records().first?.state == .failed(.bodyMissing))
        #expect(kit.session.submissions.isEmpty)
        #expect(await Self.lastSnapshot(probe) == Self.failed(.bodyMissing))
    }

    // MARK: The system's events

    @Test(.timeLimit(.minutes(1))) func awaitSystemEventsReturnsOnceTheMarkerIsApplied() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let returned = Flag()

        // Waiting first, then the marker.
        let waiting = Task {
            await kit.uploader.awaitSystemEvents(timeout: .seconds(50))
            returned.set()
        }
        await UploaderKit.settle()
        #expect(!returned.isSet)
        let clock = ContinuousClock()
        let markerApplied = clock.now
        await kit.uploader.apply(.eventsFinished)
        await waiting.value
        #expect(clock.now - markerApplied < .seconds(10))

        // The marker first, as on the phone, where the events arrive before the scene asks: the call returns at once.
        await kit.uploader.apply(.eventsFinished)
        let called = clock.now
        await kit.uploader.awaitSystemEvents(timeout: .seconds(50))
        #expect(clock.now - called < .seconds(10))
    }

    @Test(.timeLimit(.minutes(1))) func awaitSystemEventsReturnsAtTheTimeoutWhenNothingComes() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let clock = ContinuousClock()
        let called = clock.now

        await kit.uploader.awaitSystemEvents(timeout: .milliseconds(50))

        let waited = clock.now - called
        #expect(waited >= .milliseconds(50))
        #expect(waited < .seconds(10))
    }

    @Test(.timeLimit(.minutes(1))) func oneCallConsumesTheMarker() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let clock = ContinuousClock()
        await kit.uploader.apply(.eventsFinished)

        let first = clock.now
        await kit.uploader.awaitSystemEvents(timeout: .seconds(50))
        #expect(clock.now - first < .seconds(10))

        let second = clock.now
        await kit.uploader.awaitSystemEvents(timeout: .milliseconds(50))
        #expect(clock.now - second >= .milliseconds(50))
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledWaitReturnsBeforeTheTimeout() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let clock = ContinuousClock()
        let called = clock.now

        let waiting = Task { await kit.uploader.awaitSystemEvents(timeout: .seconds(50)) }
        await UploaderKit.settle()
        waiting.cancel()
        await waiting.value

        #expect(clock.now - called < .seconds(10))
        // The marker that comes later is kept for the next call.
        await kit.uploader.apply(.eventsFinished)
        let next = clock.now
        await kit.uploader.awaitSystemEvents(timeout: .seconds(50))
        #expect(clock.now - next < .seconds(10))
    }
}

/// A flag one task sets and another reads.
private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}
