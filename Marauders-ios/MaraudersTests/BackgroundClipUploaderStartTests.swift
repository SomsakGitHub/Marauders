//
//  BackgroundClipUploaderStartTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// How `BackgroundClipUploader` takes a clip on, follows its progress and settles a success. Events are applied with
/// `apply(_:)` directly: nothing pumps the session's stream yet.
struct BackgroundClipUploaderStartTests {
    private static func fileSize(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// A start that went through, with the record it left behind.
    private static func started(_ kit: UploaderKit) async throws -> UploadRecord {
        try await kit.uploader.start(kit.request())
        return try #require(kit.store.records().first)
    }

    // MARK: start

    @Test func startStagesTheBodyWritesTheRecordAndSubmitsOneTask() async throws {
        let token = UploaderKit.validToken(subject: "001234.abcdef.5678")
        let kit = UploaderKit(token: token)
        defer { kit.cleanUp() }

        try await kit.uploader.start(kit.request(byteCount: 3_000))

        let records = kit.store.records()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.state == .uploading(fraction: 0, refreshedOnce: false))
        #expect(record.accountSubject == "001234.abcdef.5678")

        #expect(kit.session.submissions.count == 1)
        let submission = try #require(kit.session.submissions.first)
        let uploadURL = try await APIConfiguration.videoUploadURL()
        #expect(submission.request.httpMethod == "POST")
        #expect(submission.request.url?.absoluteString == uploadURL.absoluteString)
        #expect(submission.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(
            submission.request.value(forHTTPHeaderField: "Content-Type")
                == "multipart/form-data; boundary=\(record.boundary)")
        #expect(
            submission.request.value(forHTTPHeaderField: "Idempotency-Key") == record.id.uuidString.lowercased())
        #expect(submission.recordID == record.id)
        #expect(submission.bodyFile == kit.store.bodyURL(id: record.id))
        #expect(Self.fileSize(of: submission.bodyFile) == record.byteCount)
        // The body holds the form around the clip, so it is bigger than the clip.
        #expect(record.byteCount > 3_000)
        #expect(submission.expectedBytes == record.byteCount)
    }

    @Test func theFirstSnapshotIsIdleAndStartPublishesUploadingAtZero() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let probe = SnapshotProbe(await kit.uploader.snapshots())

        #expect(await probe.waitForCount(1) == [.idle])

        try await kit.uploader.start(kit.request())

        #expect(await probe.waitForCount(2) == [.idle, .uploading(fraction: 0)])
    }

    // MARK: progress

    @Test func progressIsPublishedOnlyWhenTheWholePercentChanges() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        for sent in [1, 5, 9] as [Int64] {
            await kit.uploader.apply(.sentBytes(recordID: record.id, sent: sent, expected: 1_000))
        }
        await UploaderKit.settle()

        #expect(probe.values == [.uploading(fraction: 0)])
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))

        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 10, expected: 1_000))

        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), .uploading(fraction: 0.01)])
        #expect(kit.store.records().first?.state == .uploading(fraction: 0.01, refreshedOnce: false))
    }

    @Test func allBytesSentIsFinishingNotOneHundredPercent() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 1_000, expected: 1_000))

        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), .finishing])
        #expect(kit.store.records().first?.snapshot == .finishing)
    }

    @Test func aReportThatRestartsAtZeroLowersTheFraction() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 500, expected: 1_000))
        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 0, expected: 1_000))

        let expected: [UploadSnapshot] = [.uploading(fraction: 0), .uploading(fraction: 0.5), .uploading(fraction: 0)]
        #expect(await probe.waitForCount(3) == expected)
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))
    }

    @Test func aReportIsClampedAndAnUnknownTotalIsIgnored() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 300, expected: 0))
        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 300, expected: -1))
        await UploaderKit.settle()

        #expect(probe.values == [.uploading(fraction: 0)])
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: false))

        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 1_500, expected: 1_000))

        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), .finishing])
        #expect(kit.store.records().first?.state == .uploading(fraction: 1, refreshedOnce: false))
    }

    // MARK: success

    @Test func aSuccessWithABodyFinishesTheUploadAndDeletesItsBody() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)
        let clipID = UUID()
        let answer = UploaderKit.answer(id: clipID)

        // The answer arrives in two pieces, as a session may hand it over.
        await kit.uploader.apply(.receivedBody(recordID: record.id, data: answer.prefix(10)))
        await kit.uploader.apply(.receivedBody(recordID: record.id, data: answer.dropFirst(10)))
        await kit.uploader.apply(.completed(recordID: record.id, statusCode: 201, failure: nil, accessToken: "token"))

        let item = UploaderKit.item(id: clipID)
        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), .finished(item)])
        #expect(kit.store.records().first?.state == .finished(item))
        #expect(!kit.store.bodyExists(id: record.id))
        #expect(kit.storedFileNames == ["\(record.id.uuidString.lowercased()).json"])
    }

    @Test func aCompletionForADiscardedRecordChangesNothing() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        await kit.uploader.discard()
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await kit.uploader.apply(.sentBytes(recordID: record.id, sent: 500, expected: 1_000))
        await kit.uploader.apply(.receivedBody(recordID: record.id, data: UploaderKit.answer()))
        await kit.uploader.apply(.completed(recordID: record.id, statusCode: 201, failure: nil, accessToken: "token"))
        await UploaderKit.settle()

        #expect(probe.values == [.idle])
        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
    }

    @Test func anEventForAnUnknownRecordIsIgnored() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let namesBefore = kit.storedFileNames
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)
        let stranger = UUID()

        await kit.uploader.apply(.sentBytes(recordID: stranger, sent: 500, expected: 1_000))
        await kit.uploader.apply(.receivedBody(recordID: stranger, data: UploaderKit.answer()))
        await kit.uploader.apply(.completed(recordID: stranger, statusCode: 201, failure: nil, accessToken: "token"))
        await UploaderKit.settle()

        #expect(probe.values == [.uploading(fraction: 0)])
        #expect(kit.store.records() == [record])
        #expect(kit.storedFileNames == namesBefore)
    }

    @Test func aDuplicateSuccessForAFinishedRecordChangesNothing() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let first = UUID()
        await kit.uploader.apply(.receivedBody(recordID: record.id, data: UploaderKit.answer(id: first)))
        await kit.uploader.apply(.completed(recordID: record.id, statusCode: 201, failure: nil, accessToken: "token"))
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        #expect(await probe.waitForCount(1) == [.finished(UploaderKit.item(id: first))])

        // The same task is reported to have finished again, with another answer.
        await kit.uploader.apply(.receivedBody(recordID: record.id, data: UploaderKit.answer(id: UUID())))
        await kit.uploader.apply(.completed(recordID: record.id, statusCode: 201, failure: nil, accessToken: "token"))
        await UploaderKit.settle()

        #expect(probe.values == [.finished(UploaderKit.item(id: first))])
        #expect(kit.store.records().first?.state == .finished(UploaderKit.item(id: first)))
        #expect(!kit.store.bodyExists(id: record.id))
    }

    @Test func aSuccessUpgradesAnInterruptedRecord() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(.interrupted))
        let interrupted = UploadSnapshot.failed(message: "The upload was interrupted. Try again.", canRetry: true)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        #expect(await probe.waitForCount(1) == [interrupted])
        let clipID = UUID()

        await kit.uploader.apply(.receivedBody(recordID: record.id, data: UploaderKit.answer(id: clipID)))
        await kit.uploader.apply(.completed(recordID: record.id, statusCode: 201, failure: nil, accessToken: "token"))

        let item = UploaderKit.item(id: clipID)
        #expect(await probe.waitForCount(2) == [interrupted, .finished(item)])
        #expect(kit.store.records().first?.state == .finished(item))
        #expect(!kit.store.bodyExists(id: record.id))
    }

    @Test(arguments: [
        UploadFailure.rejected("Upload failed (status 400)"), .connection("The network connection was lost."),
        .responseLost,
    ])
    func aSuccessForARecordFailedForAnotherReasonIsIgnored(_ failure: UploadFailure) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: .failed(failure))
        let namesBefore = kit.storedFileNames
        let failed = UploadSnapshot.failed(message: failure.message, canRetry: failure.canRetry)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        #expect(await probe.waitForCount(1) == [failed])

        await kit.uploader.apply(.receivedBody(recordID: record.id, data: UploaderKit.answer()))
        await kit.uploader.apply(.completed(recordID: record.id, statusCode: 201, failure: nil, accessToken: "token"))
        await UploaderKit.settle()

        #expect(probe.values == [failed])
        #expect(kit.store.records() == [record])
        #expect(kit.storedFileNames == namesBefore)
        #expect(kit.resolver.questions.isEmpty)
    }

    // MARK: one slot

    @Test(arguments: [UploadRecordState.staged, .uploading(fraction: 0.3, refreshedOnce: false)])
    func aSecondStartIsRefusedWhileOneIsStagedOrUploading(_ state: UploadRecordState) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try kit.record(state: state)
        let namesBefore = kit.storedFileNames

        await #expect(throws: ClipUploadError.alreadyUploading) {
            try await kit.uploader.start(kit.request())
        }

        #expect(kit.store.records() == [record])
        #expect(kit.storedFileNames == namesBefore)
        #expect(kit.session.submissions.isEmpty)
    }

    @Test(arguments: [
        UploadRecordState.finished(UploaderKit.item()), .failed(.rejected("Upload failed (status 400)")),
        .failed(.interrupted),
    ])
    func aFinishedOrFailedRecordIsReplacedByTheNextStart(_ state: UploadRecordState) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let old = try kit.record(state: state)

        try await kit.uploader.start(kit.request())

        let records = kit.store.records()
        #expect(records.count == 1)
        #expect(records.first?.id != old.id)
        #expect(records.first?.state == .uploading(fraction: 0, refreshedOnce: false))
        #expect(!kit.store.bodyExists(id: old.id))
        #expect(kit.session.submissions.count == 1)
        // Its task is over: there is nothing to cancel.
        #expect(kit.session.cancelled.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondStartWhileTheFirstIsStillStartingIsRefused() async throws {
        let refresher = GatedRefresher(answering: .refreshed(UploaderKit.validToken()))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        let first = try await kit.request()
        let second = try await kit.request()

        let firstStart = Task { try await kit.uploader.start(first) }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }

        await #expect(throws: ClipUploadError.alreadyUploading) {
            try await kit.uploader.start(second)
        }

        await refresher.gate.open()
        try await firstStart.value
        #expect(kit.session.submissions.count == 1)
        #expect(refresher.asked.count == 1)
        #expect(kit.store.records().count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aDiscardWhileStartWaitsForTheRefreshStartsNothing() async throws {
        let refresher = GatedRefresher(answering: .refreshed(UploaderKit.validToken()))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)
        let request = try await kit.request()

        let start = Task { try await kit.uploader.start(request) }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }
        await kit.uploader.discard()
        await refresher.gate.open()

        await #expect(throws: ClipUploadError.unavailable) {
            try await start.value
        }
        await UploaderKit.settle()
        #expect(kit.session.submissions.isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.store.records().isEmpty)
        #expect(probe.values.last == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func aDiscardWhileStartWaitsForARejectedRefreshReportsNothing() async throws {
        let refresher = GatedRefresher(answering: .rejected)
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let request = try await kit.request()

        let start = Task { try await kit.uploader.start(request) }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }
        await kit.uploader.discard()
        await refresher.gate.open()

        await #expect(throws: ClipUploadError.unavailable) {
            try await start.value
        }
        #expect(kit.reports.isEmpty)
        #expect(kit.session.submissions.isEmpty)
        #expect(kit.storedFileNames.isEmpty)
    }

    // MARK: the token

    /// What is stored instead of a usable token.
    enum UnusableToken: CaseIterable, Sendable {
        case none, malformed, withoutSubject

        var stored: String? {
            switch self {
            case .none: nil
            case .malformed: "short"
            case .withoutSubject:
                TestAccessToken.make(claims: ["exp": Int(Date().timeIntervalSince1970) + 3_600])
            }
        }
    }

    @Test(arguments: UnusableToken.allCases)
    func startWithoutAUsableTokenStagesNothing(_ token: UnusableToken) async throws {
        let refresher = ScriptedRefresher()
        let kit = UploaderKit(token: token.stored, refresher: refresher)
        defer { kit.cleanUp() }

        await #expect(throws: VideoUploadAPIError.notAuthenticated) {
            try await kit.uploader.start(kit.request())
        }

        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.session.submissions.isEmpty)
        #expect(refresher.asked.isEmpty)
    }

    @Test func anExpiredTokenIsTradedBeforeStaging() async throws {
        let old = UploaderKit.expiredToken()
        let new = UploaderKit.validToken()
        let refresher = ScriptedRefresher(.refreshed(new))
        let kit = UploaderKit(token: old, refresher: refresher)
        defer { kit.cleanUp() }

        try await kit.uploader.start(kit.request())

        #expect(refresher.asked == [old])
        #expect(kit.session.submissions.count == 1)
        #expect(kit.session.submissions.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(new)")
        #expect(kit.store.records().first?.accountSubject == "user-1")
    }

    @Test func aRejectedRefreshReportsTheRejectionAndStartsNothing() async throws {
        let old = UploaderKit.expiredToken()
        let kit = UploaderKit(token: old, refresher: ScriptedRefresher(.rejected))
        defer { kit.cleanUp() }
        await kit.listenForRejections()

        await #expect(throws: VideoUploadAPIError.notAuthenticated) {
            try await kit.uploader.start(kit.request())
        }

        #expect(kit.reports == [old])
        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.session.submissions.isEmpty)
    }

    @Test func anUnavailableRefreshStartsNothing() async throws {
        let refresher = ScriptedRefresher(.unavailable(URLError(.notConnectedToInternet)))
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }
        await kit.listenForRejections()

        await #expect(throws: SessionRefreshUnavailableError()) {
            try await kit.uploader.start(kit.request())
        }

        #expect(kit.reports.isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.session.submissions.isEmpty)
    }

    // MARK: what is refused before anything is written

    @Test func notEnoughFreeSpaceStagesNothingAndSubmitsNothing() async throws {
        // The clip and the 50 MiB margin, less one byte.
        let kit = UploaderKit(freeBytes: 1_000 + 52_428_800 - 1)
        defer { kit.cleanUp() }

        await #expect(throws: ClipUploadError.notEnoughSpace) {
            try await kit.uploader.start(kit.request(byteCount: 1_000))
        }

        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.store.records().isEmpty)
        #expect(kit.session.submissions.isEmpty)
    }

    @Test func anUnsupportedOrOversizeClipIsRefusedBeforeAnythingIsWritten() async throws {
        let refresher = ScriptedRefresher()
        // An expired token: the clip is judged before the token is even looked at.
        let kit = UploaderKit(token: UploaderKit.expiredToken(), refresher: refresher)
        defer { kit.cleanUp() }

        await #expect(throws: VideoUploadAPIError.unsupportedFormat) {
            try await kit.uploader.start(kit.request(mimeType: "image/jpeg"))
        }

        let oversize = try await kit.request(byteCount: 1)
        let handle = try FileHandle(forWritingTo: oversize.fileURL)
        try handle.truncate(atOffset: UInt64(VideoUploadForm.maxUploadBytes + 1))
        try handle.close()
        await #expect(throws: VideoUploadAPIError.fileTooLarge) {
            try await kit.uploader.start(oversize)
        }

        #expect(kit.storedFileNames.isEmpty)
        #expect(kit.session.submissions.isEmpty)
        #expect(refresher.asked.isEmpty)
    }

    // MARK: discard

    @Test func discardCancelsTheTaskDeletesTheFilesAndPublishesIdle() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await kit.uploader.discard()

        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), .idle])
        #expect(kit.session.cancelled == [record.id])
        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
    }
}
