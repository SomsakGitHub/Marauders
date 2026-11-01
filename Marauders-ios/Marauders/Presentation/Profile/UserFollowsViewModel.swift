//
//  UserFollowsViewModel.swift
//  Marauders
//

import Foundation
import Observation

/// The accounts the viewer follows, shared by the feed's rail and every profile. A tap shows at once; the Worker's answer
/// then replaces the guess with its counts, and a failure puts back what was known before. One request is out at a time,
/// across all accounts: taps made meanwhile only change what is sent next, so the last tap is what the Worker ends up
/// with, and each answer counts the viewer's follows with every earlier change already in (two statements running side
/// by side would each count without the other's row).
///
/// What it learned about an account beats what a screen loaded earlier. The feed says whether the viewer followed each
/// clip's author when it loaded, which a follow since has made stale, so its word counts only for accounts nobody
/// touched here. A profile that started loading after the Worker last answered about its account is newer still, and
/// replaces what is known (`record`). Nothing here edits the feed's clips: that would restart a clip the viewer paused.
@MainActor
@Observable
final class UserFollowsViewModel {
    /// A reading of this model's clock, taken when a profile starts loading and handed back with what it found.
    struct Stamp: Equatable {
        fileprivate let generation: Int
        fileprivate let tick: Int
    }

    private struct Entry {
        /// What the viewer sees.
        var shown: Bool
        /// What the Worker, or a profile load, last said: where a failed change goes back to.
        var confirmed: Bool
        /// The account's follower count to show; nil while only the feed spoke about it, which counts nobody.
        var shownCount: Int?
        var confirmedCount: Int?
        /// The choice still to send; nil when nothing is waiting.
        var wanted: Bool?
        /// The tick at which `confirmed` was last set: a profile load that started before then may predate it.
        var settledAt: Int
    }

    /// Keyed by `UserHandle.normalized`, so the feed's and a profile's spelling of a handle are the same account.
    private var entries: [String: Entry] = [:]
    /// Accounts with a choice to send, oldest first; the first one's request is out while `isSending`.
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var isSending = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clock = 0
    private let setFollow: SetUserFollowUseCase

    /// Called with how many accounts the viewer follows each time the Worker answers a follow or an unfollow, so their
    /// own profile can show it without a reload.
    @ObservationIgnored var onViewerFollowingCountChange: ((Int) -> Void)?

    init(setFollow: SetUserFollowUseCase) {
        self.setFollow = setFollow
    }

    /// Whether the viewer follows `handle`: what is known here, else what the screen asking loaded.
    func isFollowing(_ handle: String, fallback: Bool) -> Bool {
        entries[UserHandle.normalized(handle)]?.shown ?? fallback
    }

    /// How many accounts follow `handle`: what is known here, else what the screen asking loaded.
    func followerCount(of handle: String, fallback: Int?) -> Int? {
        entries[UserHandle.normalized(handle)]?.shownCount ?? fallback
    }

    /// True while a request is out or a choice is waiting to be sent.
    var isBusy: Bool { !queue.isEmpty }

    /// Flips whether the viewer follows `handle`; `fallback` is what the screen shows while nothing is known here. The
    /// caller makes sure the viewer is signed in and the account is not their own.
    func toggle(_ handle: String, fallback: Bool) {
        let key = UserHandle.normalized(handle)
        var entry = entries[key]
            ?? Entry(shown: fallback, confirmed: fallback, shownCount: nil, confirmedCount: nil, wanted: nil, settledAt: -1)
        let following = !entry.shown
        entry.shown = following
        entry.shownCount = entry.shownCount.map { max(0, $0 + (following ? 1 : -1)) }
        entry.wanted = following
        entries[key] = entry
        // An account already queued keeps its place; its request picks up the newest choice.
        if !queue.contains(key) { queue.append(key) }
        guard !isSending else { return }
        isSending = true
        let generation = generation
        Task { await sendQueued(generation: generation) }
    }

    /// Follows `handle` unless the viewer already does: the feed's "+" only ever follows.
    func follow(_ handle: String, fallback: Bool) {
        guard !isFollowing(handle, fallback: fallback) else { return }
        toggle(handle, fallback: fallback)
    }

    /// Reads the clock before a profile load.
    func stamp() -> Stamp {
        clock += 1
        return Stamp(generation: generation, tick: clock)
    }

    /// What a profile load that started at `stamp` found about `handle`. It replaces what is known unless it may be
    /// older: a change for the account is still out, or the Worker answered one after the load started.
    func record(_ handle: String, following: Bool, followerCount: Int, loadedAt stamp: Stamp) {
        guard stamp.generation == generation else { return }
        let key = UserHandle.normalized(handle)
        // `wanted` stays set from a tap until its answer is in, so it also covers a request that is out.
        if let entry = entries[key], entry.wanted != nil || entry.settledAt > stamp.tick { return }
        let count = max(0, followerCount)
        entries[key] = Entry(
            shown: following, confirmed: following, shownCount: count, confirmedCount: count, wanted: nil, settledAt: stamp.tick
        )
    }

    /// Forgets what the viewer did: after a sign-in or sign-out the feed and the profiles load the new viewer's follows.
    func reset() {
        generation += 1
        entries = [:]
        queue = []
        isSending = false
    }

    private func sendQueued(generation: Int) async {
        while generation == self.generation, let key = queue.first {
            guard var waiting = entries[key], let following = waiting.wanted else {
                queue.removeFirst()
                continue
            }
            if following == waiting.confirmed {
                // Taps that cancelled out while the account waited its turn: the Worker already holds this.
                waiting.wanted = nil
                waiting.shown = waiting.confirmed
                waiting.shownCount = waiting.confirmedCount
                entries[key] = waiting
                queue.removeFirst()
                continue
            }
            do {
                let result = try await setFollow.execute(handle: key, following: following)
                guard generation == self.generation, var entry = entries[key] else { return }
                clock += 1
                entry.settledAt = clock
                entry.confirmed = result.following
                entry.confirmedCount = result.followerCount
                if entry.wanted == following {
                    entry.wanted = nil
                    entry.shown = result.following
                    entry.shownCount = result.followerCount
                } else if let next = entry.wanted {
                    // Tapped again while this was out: the newer choice is shown against the Worker's count.
                    let delta = next == result.following ? 0 : (next ? 1 : -1)
                    entry.shown = next
                    entry.shownCount = max(0, result.followerCount + delta)
                }
                entries[key] = entry
                onViewerFollowingCountChange?(result.viewerFollowingCount)
            } catch {
                guard generation == self.generation, var entry = entries[key] else { return }
                AppLog.warning("follows", "follow change failed: \(error.localizedDescription)")
                // A rejected session has already been ended by the transport; the reset that follows clears this too.
                entry.wanted = nil
                entry.shown = entry.confirmed
                entry.shownCount = entry.confirmedCount
                entries[key] = entry
            }
            // A choice made while this was out keeps the account first in line, so it goes next.
            if entries[key]?.wanted == nil { queue.removeFirst() }
        }
        if generation == self.generation { isSending = false }
    }
}
