//
//  BackgroundClipUploaderCompletionTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// How `BackgroundClipUploader` settles every way a task can end: a success with or without its answer, a 401 healed
/// once, the Worker's refusals and failures, a transport failure and a cancelled task. Events are applied with
/// `apply(_:)` directly.
struct BackgroundClipUploaderCompletionTests {
    /// A second token of `user-1`, other than the kit's, as a refresh hands out.
    private static let newToken = TestAccessToken.make(subject: "user-1", expiresIn: 7_200)

    /// A start that went through, with the record it left behind.
    private static func started(_ kit: UploaderKit) async throws -> UploadRecord {
        try await kit.uploader.start(kit.request())
        return try #require(kit.store.records().first)
    }

    /// The Worker's answer, if any, then the end of the task of `id`.
    private static func complete(
        _ kit: UploaderKit, _ id: UUID, status: Int?, failure: TransportFailure? = nil,
        token: String? = UploaderKit.validToken(), body: Data? = nil
    ) async {
        if let body {
            await kit.uploader.apply(.receivedBody(recordID: id, data: body))
        }
        await kit.uploader.apply(.completed(recordID: id, statusCode: status, failure: failure, accessToken: token))
    }

    private static func failed(_ failure: UploadFailure) -> UploadSnapshot {
        .failed(message: failure.message, canRetry: failure.canRetry)
    }

    // MARK: 401

    @Test func a401IsHealedByARefreshAndTheSameBodyAndKeyAreSentAgain() async throws {
        let old = UploaderKit.validToken()
        let refresher = ScriptedRefresher(.refreshed(Self.newToken))
        let kit = UploaderKit(token: old, refresher: refresher)
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await Self.complete(kit, record.id, status: 401, token: old)

        #expect(refresher.asked == [old])
        let submissions = kit.session.submissions
        #expect(submissions.count == 2)
        let first = try #require(submissions.first)
        let second = try #require(submissions.last)
        #expect(second.bodyFile == first.bodyFile)
        #expect(second.bodyFile == kit.store.bodyURL(id: record.id))
        #expect(second.recordID == record.id)
        #expect(second.expectedBytes == record.byteCount)
        #expect(
            second.request.value(forHTTPHeaderField: "Idempotency-Key")
                == first.request.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(second.request.value(forHTTPHeaderField: "Idempotency-Key") == record.id.uuidString.lowercased())
        #expect(
            second.request.value(forHTTPHeaderField: "Content-Type")
                == "multipart/form-data; boundary=\(record.boundary)")
        #expect(second.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.newToken)")
        #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: true))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), .uploading(fraction: 0)])
    }

    @Test func aSecond401EndsTheSessionAndReportsTheToken() async throws {
        let old = UploaderKit.validToken()
        let refresher = ScriptedRefresher(.refreshed(Self.newToken), .refreshed(UploaderKit.validToken()))
        let kit = UploaderKit(token: old, refresher: refresher)
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let record = try await Self.started(kit)
        await Self.complete(kit, record.id, status: 401, token: old)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await Self.complete(kit, record.id, status: 401, token: Self.newToken)

        let ended = UploadSnapshot.failed(message: "Your session ended. Sign in to try again.", canRetry: true)
        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), ended])
        #expect(kit.store.records().first?.state == .failed(.sessionEnded))
        #expect(kit.reports == [Self.newToken])
        #expect(refresher.asked == [old])
        #expect(kit.session.submissions.count == 2)
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test func aRejectedRefreshEndsTheSessionAndReportsTheToken() async throws {
        let old = UploaderKit.validToken()
        let kit = UploaderKit(token: old, refresher: ScriptedRefresher(.rejected))
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await Self.complete(kit, record.id, status: 401, token: old)

        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), Self.failed(.sessionEnded)])
        #expect(kit.store.records().first?.state == .failed(.sessionEnded))
        #expect(kit.reports == [old])
        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test func anUnavailableRefreshFailsAsUnavailable() async throws {
        let refresher = ScriptedRefresher(.unavailable(URLError(.notConnectedToInternet)))
        let kit = UploaderKit(refresher: refresher)
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await Self.complete(kit, record.id, status: 401)

        let unavailable = UploadSnapshot.failed(
            message: "The service is unavailable right now. Try again.", canRetry: true)
        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), unavailable])
        #expect(kit.store.records().first?.state == .failed(.unavailable))
        #expect(kit.reports.isEmpty)
        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test(arguments: [false, true])
    func a401InTheBackgroundResubmitsOnlyWhenThePolicyAllows(_ resubmitsWhileInBackground: Bool) async throws {
        var policy = UploadPolicy()
        policy.resubmitsWhileInBackground = resubmitsWhileInBackground
        let kit = UploaderKit(
            refresher: ScriptedRefresher(.refreshed(Self.newToken)), policy: policy, isAppActive: { false })
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)

        await Self.complete(kit, record.id, status: 401)

        if resubmitsWhileInBackground {
            #expect(kit.session.submissions.count == 2)
            #expect(kit.store.records().first?.state == .uploading(fraction: 0, refreshedOnce: true))
        } else {
            #expect(kit.session.submissions.count == 1)
            #expect(kit.store.records().first?.state == .failed(.interrupted))
            #expect(kit.store.records().first?.snapshot == Self.failed(.interrupted))
        }
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test func aRefreshedTokenOfAnotherAccountResubmitsNothing() async throws {
        let foreign = UploaderKit.validToken(subject: "user-2")
        let kit = UploaderKit(refresher: ScriptedRefresher(.refreshed(foreign)))
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let record = try await Self.started(kit)

        await Self.complete(kit, record.id, status: 401)

        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.records().first?.state == .failed(.sessionEnded))
        #expect(kit.store.records().first?.snapshot == Self.failed(.sessionEnded))
        #expect(kit.reports.isEmpty)
    }

    @Test func aHealWithoutTheBodyFileFailsAsBodyMissing() async throws {
        let kit = UploaderKit(refresher: ScriptedRefresher(.refreshed(Self.newToken)))
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        kit.store.deleteBody(id: record.id)

        await Self.complete(kit, record.id, status: 401)

        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.records().first?.state == .failed(.bodyMissing))
        #expect(
            kit.store.records().first?.snapshot
                == .failed(message: "The clip is no longer on this iPhone. Choose the video again.", canRetry: false))
    }

    @Test func aSessionEndWithNoTokenFailsWithoutAskingTheRefresher() async throws {
        let refresher = ScriptedRefresher(.refreshed(Self.newToken))
        let kit = UploaderKit(refresher: refresher)
        defer { kit.cleanUp() }
        await kit.listenForRejections()
        let record = try await Self.started(kit)

        await Self.complete(kit, record.id, status: 401, token: nil)

        #expect(refresher.asked.isEmpty)
        #expect(kit.reports.isEmpty)
        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.records().first?.state == .failed(.sessionEnded))
    }

    @Test func aSessionEndWithNoReporterStillFails() async throws {
        let kit = UploaderKit(refresher: ScriptedRefresher(.refreshed(Self.newToken)))
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        await Self.complete(kit, record.id, status: 401)

        await Self.complete(kit, record.id, status: 401, token: Self.newToken)

        #expect(kit.store.records().first?.state == .failed(.sessionEnded))
        #expect(kit.store.records().first?.snapshot == Self.failed(.sessionEnded))
        #expect(kit.session.submissions.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aDiscardWhileTheRefreshIsOutLeavesNothingBehind() async throws {
        let refresher = GatedRefresher(answering: .refreshed(Self.newToken))
        let kit = UploaderKit(refresher: refresher)
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        let completion = Task { await Self.complete(kit, record.id, status: 401) }
        await UploaderKit.waitUntil { !refresher.asked.isEmpty }
        await kit.uploader.discard()
        await refresher.gate.open()
        await completion.value
        await UploaderKit.settle()

        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(probe.values == [.uploading(fraction: 0), .idle])
    }

    // MARK: the Worker's refusals and failures

    @Test(arguments: [502, 503, 504])
    func aGatewayErrorFailsWithTryAgainAndSubmitsNothing(_ status: Int) async throws {
        let refresher = ScriptedRefresher()
        let kit = UploaderKit(refresher: refresher)
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await Self.complete(kit, record.id, status: status)

        let unavailable = UploadSnapshot.failed(
            message: "The service is unavailable right now. Try again.", canRetry: true)
        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), unavailable])
        #expect(kit.store.records().first?.state == .failed(.unavailable))
        #expect(kit.session.submissions.count == 1)
        #expect(refresher.asked.isEmpty)
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test(arguments: [
        TransportFailure.connection("The network connection was lost."), .other("The request timed out."),
    ])
    func aTransportFailureShowsItsTextAndCanBeRetried(_ failure: TransportFailure) async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)
        let text =
            switch failure {
            case .connection(let text), .other(let text): text
            case .cancelled: ""
            }

        await Self.complete(kit, record.id, status: nil, failure: failure)

        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), .failed(message: text, canRetry: true)])
        #expect(kit.store.records().first?.state == .failed(.connection(text)))
        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test func aStatusCodeWinsOverATransportFailure() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let clipID = UUID()

        await Self.complete(
            kit, record.id, status: 201, failure: .connection("The network connection was lost."),
            body: UploaderKit.answer(id: clipID))

        #expect(kit.store.records().first?.state == .finished(UploaderKit.item(id: clipID)))
        #expect(!kit.store.bodyExists(id: record.id))
    }

    @Test func a429SaysTooManyUploads() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)

        await Self.complete(kit, record.id, status: 429, body: Data(#"{"error":"Slow down"}"#.utf8))

        #expect(kit.store.records().first?.state == .failed(.rateLimited))
        #expect(
            kit.store.records().first?.snapshot
                == .failed(message: "Too many uploads, try again in a minute", canRetry: true))
        #expect(kit.session.submissions.count == 1)
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test func aRejectedUploadDeletesItsBodyAndIsNotRetried() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        let answer = Data(#"{"error":"Video must be 100 MB or smaller"}"#.utf8)
        await Self.complete(kit, record.id, status: 400, body: answer)

        let rejected = UploadSnapshot.failed(message: "Video must be 100 MB or smaller", canRetry: false)
        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), rejected])
        #expect(kit.store.records().first?.state == .failed(.rejected("Video must be 100 MB or smaller")))
        #expect(!kit.store.bodyExists(id: record.id))
        #expect(kit.storedFileNames == ["\(record.id.uuidString.lowercased()).json"])
        #expect(kit.session.submissions.count == 1)
    }

    @Test func aRejectionWithoutTheWorkersTextNamesTheStatus() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)

        await Self.complete(kit, record.id, status: 413)

        #expect(kit.store.records().first?.state == .failed(.rejected("Upload failed (status 413)")))
        #expect(!kit.store.bodyExists(id: record.id))
    }

    @Test func aServerErrorKeepsTheBodyAndCanBeRetried() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await Self.complete(kit, record.id, status: 500)

        let serverError = UploadSnapshot.failed(message: "Upload failed (status 500)", canRetry: true)
        #expect(await probe.waitForCount(2) == [.uploading(fraction: 0), serverError])
        #expect(kit.store.records().first?.state == .failed(.serverError("Upload failed (status 500)")))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.submissions.count == 1)
    }

    // MARK: a task that ends without an answer

    @Test func aCancelledTaskIsInterruptedUnlessTheRecordIsGone() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)

        await Self.complete(kit, record.id, status: nil, failure: .cancelled)

        #expect(kit.store.records().first?.state == .failed(.interrupted))
        #expect(kit.store.records().first?.snapshot == Self.failed(.interrupted))
        #expect(kit.store.bodyExists(id: record.id))

        await kit.uploader.discard()
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)

        await Self.complete(kit, record.id, status: nil, failure: .cancelled)
        await UploaderKit.settle()

        #expect(kit.store.records().isEmpty)
        #expect(kit.storedFileNames.isEmpty)
        #expect(probe.values == [.idle])
    }

    @Test func aCompletionWithNoStatusAndNoFailureIsInterrupted() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)

        await Self.complete(kit, record.id, status: nil, failure: nil)

        #expect(kit.store.records().first?.state == .failed(.interrupted))
        #expect(kit.store.bodyExists(id: record.id))
        #expect(kit.session.submissions.count == 1)
    }

    @Test func aCompletionThatArrivesAfterTheInterruptedVerdictWins() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        await Self.complete(kit, record.id, status: nil, failure: .cancelled)
        #expect(kit.store.records().first?.state == .failed(.interrupted))
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        await probe.waitForCount(1)
        let clipID = UUID()

        // A second interrupted verdict changes nothing.
        await Self.complete(kit, record.id, status: nil, failure: .cancelled)
        await Self.complete(kit, record.id, status: 201, body: UploaderKit.answer(id: clipID))

        let item = UploaderKit.item(id: clipID)
        #expect(await probe.waitForCount(2) == [Self.failed(.interrupted), .finished(item)])
        #expect(kit.store.records().first?.state == .finished(item))
        #expect(!kit.store.bodyExists(id: record.id))
    }

    // MARK: a success whose answer was lost

    @Test func aSuccessWithoutABodyAsksTheWorkerForTheStoredClip() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        let item = UploaderKit.item()
        kit.resolver.answer = item
        let token = UploaderKit.validToken()

        await Self.complete(kit, record.id, status: 201, token: token, body: Data("not json".utf8))

        #expect(kit.resolver.questions == [.init(key: record.id, accessToken: token)])
        #expect(kit.store.records().first?.state == .finished(item))
        #expect(kit.store.records().first?.snapshot == .finished(item))
        #expect(!kit.store.bodyExists(id: record.id))
    }

    @Test func aReplayThatFailsLeavesAResponseLostFailure() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        kit.resolver.answer = nil

        await Self.complete(kit, record.id, status: 201)

        #expect(kit.resolver.questions.count == 1)
        #expect(kit.store.records().first?.state == .failed(.responseLost))
        #expect(
            kit.store.records().first?.snapshot
                == .failed(
                    message: "The clip may have been uploaded, but the answer was lost. Try again.", canRetry: true))
        #expect(kit.store.bodyExists(id: record.id))
    }

    @Test func aSuccessWithoutAnAnswerAndWithoutATokenIsAResponseLost() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let record = try await Self.started(kit)
        kit.resolver.answer = UploaderKit.item()

        await Self.complete(kit, record.id, status: 201, token: nil)

        #expect(kit.resolver.questions.isEmpty)
        #expect(kit.store.records().first?.state == .failed(.responseLost))
        #expect(kit.store.bodyExists(id: record.id))
    }

    // MARK: what a completion leaves alone

    /// How a task ends, for the tests that try several.
    enum Ending: Sendable, CustomTestStringConvertible {
        case status(Int)
        case cancelled

        var statusCode: Int? {
            if case .status(let code) = self { code } else { nil }
        }

        var failure: TransportFailure? {
            if case .cancelled = self { .cancelled } else { nil }
        }

        var testDescription: String {
            switch self {
            case .status(let code): "status \(code)"
            case .cancelled: "cancelled"
            }
        }
    }

    @Test(arguments: [Ending.status(401), .status(429), .status(500), .cancelled])
    func aCompletionForARecordThatTakesNoneChangesNothing(_ ending: Ending) async throws {
        let refresher = ScriptedRefresher(.refreshed(Self.newToken))
        let kit = UploaderKit(refresher: refresher)
        defer { kit.cleanUp() }
        let item = UploaderKit.item()
        let record = try kit.record(state: .finished(item), withBody: false)
        kit.resolver.answer = item
        let namesBefore = kit.storedFileNames
        let probe = SnapshotProbe(await kit.uploader.snapshots())
        #expect(await probe.waitForCount(1) == [.finished(item)])

        await Self.complete(kit, record.id, status: ending.statusCode, failure: ending.failure)
        await UploaderKit.settle()

        #expect(refresher.asked.isEmpty)
        #expect(kit.resolver.questions.isEmpty)
        #expect(kit.session.submissions.isEmpty)
        #expect(probe.values == [.finished(item)])
        #expect(kit.store.records() == [record])
        #expect(kit.storedFileNames == namesBefore)
    }

    @Test func everyCompletionDropsItsBufferedAnswer() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let endings: [Ending] = [.status(201), .status(500), .status(429), .cancelled]

        for ending in endings {
            let record = try kit.record()
            await kit.uploader.apply(.receivedBody(recordID: record.id, data: UploaderKit.answer()))
            #expect(await kit.uploader.responseBodies[record.id] != nil)

            await Self.complete(kit, record.id, status: ending.statusCode, failure: ending.failure)

            #expect(await kit.uploader.responseBodies[record.id] == nil, "\(ending.testDescription)")
            let state = kit.store.records().first { $0.id == record.id }?.state
            #expect(state != .uploading(fraction: 0, refreshedOnce: false))
        }
    }
}
