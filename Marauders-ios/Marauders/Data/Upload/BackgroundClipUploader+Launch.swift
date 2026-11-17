//
//  BackgroundClipUploader+Launch.swift
//  Marauders
//

import Foundation
import MaraudersAuth

/// What a launch does with the upload left on disk, the viewer's Try again, and the wait for the system to hand its
/// events over.
extension BackgroundClipUploader {
    /// One `awaitSystemEvents` call waiting for the marker, with the timer that ends its wait.
    struct SystemEventsWaiter {
        let key: UUID
        let continuation: CheckedContinuation<Void, Never>
        let timer: Task<Void, Never>
    }

    // MARK: Launch

    /// Starts applying the session's events, in order, once however often it is called, then reconciles the stored
    /// upload. The pump does not keep the uploader alive.
    func launch() async {
        if pump == nil {
            let events = session.events
            pump = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.apply(event)
                }
            }
        }
        await reconcile()
    }

    // MARK: Reconcile

    /// Brings the stored upload in line with the world as it is now, after a launch or a sign in, and publishes the
    /// current snapshot.
    ///
    /// Orphan bodies go; so does a record older than `policy.maxAge`, and, when a token is stored, a record of another
    /// account (an unreadable `sub` counts as another account), each with its task cancelled. A `staged` record is
    /// marked `uploading` when the session lists its task and sent now otherwise; an `uploading` record whose task is
    /// not listed failed as `interrupted`, or as `bodyMissing` when its body is gone. `finished` and `failed` records
    /// are kept. While a `start` or a `retry()` runs, the sweep is skipped and every `staged` record is left alone:
    /// there is one upload at a time, so that record is theirs. Every record is read again after each `await`.
    func reconcile() async {
        if !isBusy {
            store.removeOrphanBodies()
        }
        let stored = await storedAccessToken()
        // A task the system finished but has not yet delivered is listed too: listed is not running.
        let pending = await session.pendingRecordIDs()
        for id in store.records().map(\.id) {
            await reconcile(recordID: id, stored: stored, pending: pending)
        }
        publish(store.records().first?.snapshot ?? .idle)
    }

    /// A `start` or a `retry()` is running.
    private var isBusy: Bool { isStarting || isRetrying }

    private func reconcile(recordID: UUID, stored: (token: String, subject: String?)?, pending: Set<UUID>) async {
        guard let record = record(recordID) else { return }
        if record.state == .staged, isBusy { return }
        if now().timeIntervalSince(record.createdAt) >= policy.maxAge {
            await drop(record, because: "expired")
            return
        }
        if let stored, stored.subject != record.accountSubject {
            await drop(record, because: "another account")
            return
        }

        switch record.state {
        case .staged:
            if pending.contains(recordID) {
                markUploading(record)
            } else if !store.bodyExists(id: recordID) {
                await settle(recordID: recordID, as: .bodyMissing)
            } else if let stored {
                await resubmit(record, accessToken: stored.token, refreshedOnce: false)
            } else {
                await settle(recordID: recordID, as: .sessionEnded)
            }
        case .uploading:
            guard !pending.contains(recordID) else { return }
            await settle(recordID: recordID, as: store.bodyExists(id: recordID) ? .interrupted : .bodyMissing)
        case .finished, .failed:
            return
        }
    }

    /// Deletes the record and its body, then cancels its task, as `discard()` does.
    private func drop(_ record: UploadRecord, because reason: String) async {
        store.delete(id: record.id)
        responseBodies[record.id] = nil
        await session.cancel(recordID: record.id)
        await AppLog.info("upload.bg", "\(Self.shortID(record.id)) deleted: \(reason)")
    }

    /// Records that the task of `record` is on its way, and publishes it.
    private func markUploading(_ record: UploadRecord) {
        var record = record
        record.state = .uploading(fraction: 0, refreshedOnce: false)
        try? store.save(record)
        publish(record.snapshot)
    }

    // MARK: Try again

    /// Sends the clip again after a failure that allows it: the same id, key, boundary and body, with the refresh flag
    /// reset. Does nothing for any other state, or while another `retry()` runs.
    ///
    /// The record is first saved as `staged`, so a completion settles it as it would any upload. With no token stored
    /// the upload fails as `sessionEnded`; a token of another account deletes the record and its body; an expired one
    /// is traded first. After every `await` the record is read again, and nothing more is done when it was discarded,
    /// deleted or settled meanwhile. When the session still lists the old task, nothing is sent again.
    func retry() async {
        guard !isRetrying, var record = store.records().first, case .failed(let failure) = record.state,
            failure.canRetry
        else { return }
        isRetrying = true
        defer { isRetrying = false }
        let discards = discardCount

        record.state = .staged
        do {
            try store.save(record)
        } catch {
            await AppLog.warning("upload.bg", "\(Self.shortID(record.id)) retry not saved")
            return
        }
        publish(record.snapshot)

        let stored = await storedAccessToken()
        guard stillStaged(record.id, discards: discards) != nil else { return }
        guard let stored else {
            await settle(recordID: record.id, as: .sessionEnded)
            return
        }
        guard stored.subject == record.accountSubject else {
            forget(record)
            return
        }

        var token = stored.token
        if APIAccessTokenExpiry.isExpired(token, now: now()) {
            let outcome = await refresher.refreshedAccessToken(replacing: token)
            guard stillStaged(record.id, discards: discards) != nil else { return }
            switch outcome {
            case .refreshed(let newToken):
                guard Self.accountSubject(of: newToken) == record.accountSubject else {
                    forget(record)
                    return
                }
                token = newToken
            case .rejected:
                if await settle(recordID: record.id, as: .sessionEnded) {
                    await rejectionReporter?(token)
                }
                return
            case .unavailable:
                await settle(recordID: record.id, as: .unavailable)
                return
            }
        }

        let pending = await session.pendingRecordIDs()
        guard let current = stillStaged(record.id, discards: discards) else { return }
        if pending.contains(record.id) {
            // The old task is still alive: its end settles the upload.
            markUploading(current)
            return
        }
        await resubmit(current, accessToken: token, refreshedOnce: false)
    }

    /// The record of `recordID` when it is still `staged` and no discard happened since `discards` was read.
    private func stillStaged(_ recordID: UUID, discards: Int) -> UploadRecord? {
        guard discardCount == discards, let record = record(recordID), record.state == .staged else { return nil }
        return record
    }

    /// Deletes the record and its body, never to be sent under another account, and publishes `.idle`.
    private func forget(_ record: UploadRecord) {
        store.delete(id: record.id)
        responseBodies[record.id] = nil
        publish(.idle)
    }

    // MARK: The system's events

    /// Returns once the system has handed over every event it held for the session, at `timeout`, or when the caller
    /// is cancelled, whichever comes first.
    ///
    /// The system delivers the events before the scene asks, so a marker already applied makes the call return at
    /// once. One call consumes one marker. The pump applies events one at a time, so a marker queued behind a
    /// `.completed` whose refresher call is out can arrive late (the 25 s timeout covers a normal refresher call).
    func awaitSystemEvents(timeout: Duration = .seconds(25)) async {
        if eventsFinishedUnclaimed {
            eventsFinishedUnclaimed = false
            return
        }
        guard !Task.isCancelled else { return }
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.endWait(key)
                }
                systemEventsWaiters.append(SystemEventsWaiter(key: key, continuation: continuation, timer: timer))
            }
        } onCancel: {
            Task { await self.endWait(key) }
        }
    }

    /// The marker: resumes the oldest waiting call, or keeps the marker for the next one.
    func systemEventsFinished() {
        guard !systemEventsWaiters.isEmpty else {
            eventsFinishedUnclaimed = true
            return
        }
        resume(systemEventsWaiters.removeFirst())
    }

    /// Ends the wait of `key`, when it is still waiting.
    private func endWait(_ key: UUID) {
        guard let index = systemEventsWaiters.firstIndex(where: { $0.key == key }) else { return }
        resume(systemEventsWaiters.remove(at: index))
    }

    private func resume(_ waiter: SystemEventsWaiter) {
        waiter.timer.cancel()
        waiter.continuation.resume()
    }
}
