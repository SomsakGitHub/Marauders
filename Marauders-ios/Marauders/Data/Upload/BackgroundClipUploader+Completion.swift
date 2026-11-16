//
//  BackgroundClipUploader+Completion.swift
//  Marauders
//

import Foundation

/// Every way a task of the background session can end, and what the record of its upload becomes.
extension BackgroundClipUploader {
    /// Settles the end of the task of `recordID`. A status code wins over a transport failure: the Worker answered.
    ///
    /// The buffered answer is dropped whatever follows. A record that is gone, or that does not take a completion,
    /// keeps its state, and nothing is asked, written, reported or submitted for it. After every `await` the record
    /// and the discard counter are read again, and a record that was discarded or settled meanwhile is left alone.
    func complete(recordID: UUID, statusCode: Int?, failure: TransportFailure?, accessToken: String?) async {
        let body = responseBodies.removeValue(forKey: recordID)
        guard let record = record(recordID), Self.takesCompletion(record.state) else { return }
        let discards = discardCount

        guard let statusCode else {
            switch failure {
            case .connection(let text), .other(let text):
                await settle(recordID: recordID, as: .connection(text))
            case .cancelled, nil:
                await settle(recordID: recordID, as: .interrupted)
            }
            return
        }

        switch statusCode {
        case 200..<300:
            if let body, let item = try? VideoUploadForm.decodeItem(from: body) {
                await finish(recordID: recordID, with: item)
            } else {
                await resolveLostAnswer(recordID: recordID, accessToken: accessToken, discards: discards)
            }
        case 401:
            await heal(record, rejectedAccessToken: accessToken, discards: discards)
        case 429:
            await settle(recordID: recordID, as: .rateLimited)
        case 502, 503, 504:
            await settle(recordID: recordID, as: .unavailable)
        case 400..<500:
            await settle(
                recordID: recordID, as: .rejected(Self.workerMessage(body, statusCode: statusCode)), deleteBody: true)
        default:
            await settle(recordID: recordID, as: .serverError(Self.workerMessage(body, statusCode: statusCode)))
        }
    }

    /// The Worker's `error` text from its answer, else `Upload failed (status N)`.
    private static func workerMessage(_ body: Data?, statusCode: Int) -> String {
        body.flatMap(VideoUploadForm.serverMessage(from:)) ?? "Upload failed (status \(statusCode))"
    }

    /// A 2xx whose answer never arrived whole: asks the Worker for the clip it stored under the record's key.
    private func resolveLostAnswer(recordID: UUID, accessToken: String?, discards: Int) async {
        guard let accessToken else {
            await settle(recordID: recordID, as: .responseLost)
            return
        }
        let item: FeedVideo?
        do {
            item = try await resolver.storedClip(forKey: recordID, accessToken: accessToken)
        } catch {
            item = nil
        }
        guard stillTakesCompletion(recordID, discards: discards) != nil else { return }
        if let item {
            await finish(recordID: recordID, with: item)
        } else {
            await settle(recordID: recordID, as: .responseLost)
        }
    }

    /// A 401: the first one is healed with a new token and the same body, the second ends the session.
    private func heal(_ record: UploadRecord, rejectedAccessToken: String?, discards: Int) async {
        guard let rejectedAccessToken else {
            await settle(recordID: record.id, as: .sessionEnded)
            return
        }
        if case .uploading(_, refreshedOnce: true) = record.state {
            await endSession(recordID: record.id, rejectedAccessToken: rejectedAccessToken)
            return
        }

        let outcome = await refresher.refreshedAccessToken(replacing: rejectedAccessToken)
        guard var current = stillTakesCompletion(record.id, discards: discards) else { return }
        switch outcome {
        case .refreshed(let newToken):
            // The Worker keeps an idempotency key per owner: another account's token would store the clip as theirs.
            guard APIAccessTokenFormat.isValid(newToken),
                APIAccessTokenSubject.subject(of: newToken) == current.accountSubject
            else {
                await settle(recordID: record.id, as: .sessionEnded)
                return
            }
            if !policy.resubmitsWhileInBackground {
                let isActive = await isAppActive()
                guard let reread = stillTakesCompletion(record.id, discards: discards) else { return }
                guard isActive else {
                    await settle(recordID: record.id, as: .interrupted)
                    return
                }
                current = reread
            }
            await resubmit(current, accessToken: newToken, refreshedOnce: true)
        case .rejected:
            await endSession(recordID: record.id, rejectedAccessToken: rejectedAccessToken)
        case .unavailable:
            await settle(recordID: record.id, as: .unavailable)
        }
    }

    /// Fails the upload as `sessionEnded` and reports the token the Worker refused for good.
    private func endSession(recordID: UUID, rejectedAccessToken: String) async {
        guard await settle(recordID: recordID, as: .sessionEnded) else { return }
        await rejectionReporter?(rejectedAccessToken)
    }

    /// Sends the staged body of `record` again, under the same idempotency key, with `accessToken`, and records it as
    /// `.uploading(fraction: 0, refreshedOnce:)`.
    ///
    /// The 401 heal calls it with `refreshedOnce: true`; Try again calls it with `false`. A body that is gone fails the
    /// upload as `bodyMissing`; a request that cannot be built fails it as `interrupted` and keeps the body. Nothing
    /// is submitted when the record was discarded or settled while the request was built.
    func resubmit(_ record: UploadRecord, accessToken: String, refreshedOnce: Bool) async {
        let discards = discardCount
        guard store.bodyExists(id: record.id) else {
            await settle(recordID: record.id, as: .bodyMissing)
            return
        }
        let request: URLRequest
        do {
            request = try await VideoUploadForm.request(
                authorizationHeader: "Bearer " + accessToken, boundary: record.boundary, idempotencyKey: record.id)
        } catch {
            guard stillTakesCompletion(record.id, discards: discards) != nil else { return }
            await settle(recordID: record.id, as: .interrupted)
            return
        }
        guard var current = stillTakesCompletion(record.id, discards: discards) else { return }

        session.submit(
            request, bodyFile: store.bodyURL(id: record.id), recordID: record.id, expectedBytes: record.byteCount)
        current.state = .uploading(fraction: 0, refreshedOnce: refreshedOnce)
        let saved = (try? store.save(current)) != nil
        publish(current.snapshot)

        // A record left in its earlier state is put right by reconcile, which finds the task.
        if saved {
            await AppLog.info("upload.bg", "\(Self.shortID(record.id)) resubmitted")
        } else {
            await AppLog.warning("upload.bg", "\(Self.shortID(record.id)) resubmitted, record not saved")
        }
    }

    /// The record of `recordID` when it still takes a completion and no discard happened since `discards` was read.
    private func stillTakesCompletion(_ recordID: UUID, discards: Int) -> UploadRecord? {
        guard discardCount == discards, let record = record(recordID), Self.takesCompletion(record.state) else {
            return nil
        }
        return record
    }

    /// Fails the upload of `recordID` with `failure`, deleting its body after the record is saved when `deleteBody`
    /// says so, and publishes the snapshot. A record that is gone or does not take a completion is left alone, and so
    /// is one already failed the same way.
    ///
    /// - Returns: Whether the record took the verdict, an unsaved verdict included: the token a caller reports is dead
    ///   either way.
    @discardableResult
    func settle(recordID: UUID, as failure: UploadFailure, deleteBody: Bool = false) async -> Bool {
        guard var record = record(recordID), Self.takesCompletion(record.state), record.state != .failed(failure) else {
            return false
        }
        record.state = .failed(failure)
        do {
            try store.save(record)
        } catch {
            await AppLog.warning("upload.bg", "\(Self.shortID(recordID)) failed: \(Self.name(of: failure)), not saved")
            return true
        }
        if deleteBody {
            store.deleteBody(id: recordID)
        }
        publish(record.snapshot)
        await AppLog.info("upload.bg", "\(Self.shortID(recordID)) failed: \(Self.name(of: failure))")
        return true
    }

    /// The name of the case, without the text a case may carry: a log line never holds the Worker's words.
    private static func name(of failure: UploadFailure) -> String {
        switch failure {
        case .sessionEnded: "sessionEnded"
        case .unavailable: "unavailable"
        case .connection: "connection"
        case .rateLimited: "rateLimited"
        case .rejected: "rejected"
        case .serverError: "serverError"
        case .interrupted: "interrupted"
        case .responseLost: "responseLost"
        case .bodyMissing: "bodyMissing"
        }
    }
}
