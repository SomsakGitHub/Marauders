//
//  ClipLikesViewModel.swift
//  Marauders
//

import Foundation
import Observation

/// The viewer's likes on feed clips. A tap shows at once; the Worker's answer then replaces the guess with its count,
/// and a failure puts back what the Worker last said. One request per clip is out at a time: taps made meanwhile only
/// change what is sent next, so the last tap is what the Worker ends up with.
///
/// The feed's clips are not changed (that would restart a clip the viewer paused). What the viewer did sits beside
/// them, and gives way as soon as a feed reload says something else about the clip, because that is newer.
@MainActor
@Observable
final class ClipLikesViewModel {
    /// What the feed said about a clip when the viewer tapped it.
    private struct FeedSnapshot: Equatable {
        let count: Int?
        let liked: Bool?

        init(_ clip: FeedVideo) {
            count = clip.likeCount
            liked = clip.likedByViewer
        }
    }

    private struct Entry {
        let base: FeedSnapshot
        /// What the viewer sees.
        var shown: ClipLikeState
        /// What the Worker last said, or the feed before its first answer: where a failed change goes back to.
        var confirmed: ClipLikeState
        /// The choice still to send; nil when nothing is waiting.
        var wanted: Bool?
    }

    private var entries: [UUID: Entry] = [:]
    /// Clips with a request out. Kept apart from the entries: a feed reload replaces a clip's entry, not its request.
    @ObservationIgnored private var sending: Set<UUID> = []
    @ObservationIgnored private var generation = 0
    private let setLike: SetClipLikeUseCase

    init(setLike: SetClipLikeUseCase) {
        self.setLike = setLike
    }

    func state(for clip: FeedVideo) -> ClipLikeState {
        if let entry = entries[clip.id], entry.base == FeedSnapshot(clip) { return entry.shown }
        return Self.feedState(of: clip)
    }

    /// True while a request is out or a choice is waiting to be sent.
    var isBusy: Bool { !sending.isEmpty }

    /// Flips the viewer's like on `clip`. The caller makes sure the viewer is signed in.
    func toggle(_ clip: FeedVideo) {
        let current = state(for: clip)
        let liked = !current.liked
        let shown = ClipLikeState(liked: liked, count: max(0, current.count + (liked ? 1 : -1)))
        var entry: Entry
        if let existing = entries[clip.id], existing.base == FeedSnapshot(clip) {
            entry = existing
        } else {
            // The feed reloaded since the last tap (or there was none): start from what it says now.
            entry = Entry(base: FeedSnapshot(clip), shown: current, confirmed: current)
        }
        entry.shown = shown
        entry.wanted = liked
        entries[clip.id] = entry
        guard sending.insert(clip.id).inserted else { return }
        let generation = generation
        Task { await send(clip.id, generation: generation) }
    }

    /// Forgets what the viewer did: after a sign-in or sign-out the feed reloads with the new viewer's likes.
    func reset() {
        generation += 1
        entries = [:]
        sending = []
    }

    private static func feedState(of clip: FeedVideo) -> ClipLikeState {
        ClipLikeState(liked: clip.likedByViewer ?? false, count: max(0, clip.likeCount ?? 0))
    }

    private func send(_ id: UUID, generation: Int) async {
        while generation == self.generation, let liked = entries[id]?.wanted {
            do {
                let result = try await setLike.execute(videoID: id, liked: liked)
                guard generation == self.generation, var entry = entries[id] else { return }
                entry.confirmed = result
                if entry.wanted == liked {
                    entry.wanted = nil
                    entry.shown = result
                } else if let next = entry.wanted {
                    // Tapped again while this was out: the newer choice is shown against the Worker's count.
                    let delta = next == result.liked ? 0 : (next ? 1 : -1)
                    entry.shown = ClipLikeState(liked: next, count: max(0, result.count + delta))
                }
                entries[id] = entry
            } catch {
                guard generation == self.generation, var entry = entries[id] else { return }
                AppLog.warning("likes", "like change failed: \(error.localizedDescription)")
                // A rejected session has already been ended by the transport; the reset that follows clears this too.
                entry.wanted = nil
                entry.shown = entry.confirmed
                entries[id] = entry
            }
        }
        if generation == self.generation { sending.remove(id) }
    }
}
