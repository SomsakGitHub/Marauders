//
//  FriendLocationsViewModel.swift
//  Marauders
//

import Foundation
import Observation

/// The viewer's location sharing and the mutual followers it shows on the map. Sharing works both ways: the Worker shows
/// the viewer's last location to the people they follow who follow them back, and theirs to the viewer, only while both
/// share and the viewer's own location is on file. It is off until the viewer turns it on.
@MainActor
@Observable
final class FriendLocationsViewModel {
    /// Pins older than this without a successful refresh are taken off: the friend may have stopped sharing since.
    static let staleAfter: TimeInterval = 5 * 60

    /// Whether the viewer shares their location; nil until the Worker has said, and again after the session ends.
    private(set) var sharing: Bool?
    /// Whether the viewer's own location is on file. Right after sharing is turned on it is not (the Worker forgets the
    /// one from before), and nobody shows until the viewer's iPhone has sent one.
    private(set) var located = true
    /// The mutual followers who share, with where they were last. Empty while the viewer does not share.
    private(set) var friends: [FriendLocation] = []
    private(set) var isChangingSharing = false

    private let loadFriends: LoadFriendLocationsUseCase
    private let changeSharing: SetLocationSharingUseCase
    private let reporter: ForegroundLocationReporter?
    private let now: () -> Date
    /// Bumped when the session ends, so an answer that was still out then changes nothing.
    @ObservationIgnored private var generation = 0
    /// Bumped as a sharing change starts and again once it is answered: a refresh out across either is older than the
    /// change and must not undo it.
    @ObservationIgnored private var sharingRevision = 0
    @ObservationIgnored private var lastLoadedAt: Date?

    init(
        loadFriends: LoadFriendLocationsUseCase,
        setSharing: SetLocationSharingUseCase,
        reporter: ForegroundLocationReporter? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.loadFriends = loadFriends
        self.changeSharing = setSharing
        self.reporter = reporter
        self.now = now
        reporter?.shouldSend = { [weak self] in self?.sharing == true }
        reporter?.onReported = { [weak self] in
            // The viewer's first location since sharing went on: the Worker shows them their friends now.
            guard let self, sharing == true, !located else { return }
            Task { await self.refresh() }
        }
    }

    /// Asks the Worker again. A failure keeps what is shown for a while; the map asks again shortly.
    func refresh() async {
        let generation = generation
        let revision = sharingRevision
        do {
            let result = try await loadFriends.execute()
            guard generation == self.generation, revision == sharingRevision else { return }
            sharing = result.sharing
            located = result.located
            friends = result.sharing ? result.friends : []
            lastLoadedAt = now()
        } catch {
            guard generation == self.generation else { return }
            if let lastLoadedAt, now().timeIntervalSince(lastLoadedAt) > Self.staleAfter { friends = [] }
            AppLog.warning("friends", "friend locations failed: \(error.localizedDescription)")
        }
    }

    /// Turns sharing on or off. Turning it on sends the viewer's location at once and fetches their friends'; turning it
    /// off hides them at once and drops a location still on its way. Returns what went wrong, for the screen that asked
    /// to say so; nil when it went through (or the session ended meanwhile).
    @discardableResult
    func setSharing(_ enabled: Bool) async -> String? {
        guard !isChangingSharing else { return nil }
        let generation = generation
        sharingRevision += 1
        isChangingSharing = true
        if !enabled { reporter?.reset() }
        do {
            let stored = try await changeSharing.execute(enabled: enabled)
            guard generation == self.generation else { return nil }
            sharingRevision += 1
            sharing = stored
            isChangingSharing = false
            if stored {
                reporter?.reportIfDue(force: true)
                await refresh()
            } else {
                friends = []
            }
            return nil
        } catch {
            guard generation == self.generation else { return nil }
            sharingRevision += 1
            isChangingSharing = false
            AppLog.warning("friends", "sharing change failed: \(error.localizedDescription)")
            return (error as? LocalizedError)?.errorDescription ?? "Couldn't change location sharing"
        }
    }

    /// Sends the viewer's location if they share it and none went out lately.
    func reportLocationIfDue() {
        guard sharing == true else { return }
        reporter?.reportIfDue()
    }

    /// Forgets the ended session's sharing and friends, and drops a location still on its way.
    func reset() {
        generation += 1
        sharing = nil
        located = true
        friends = []
        isChangingSharing = false
        lastLoadedAt = nil
        reporter?.reset()
    }
}
