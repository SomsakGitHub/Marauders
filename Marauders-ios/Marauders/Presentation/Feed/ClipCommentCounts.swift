//
//  ClipCommentCounts.swift
//  Marauders
//

import Foundation

/// How many comments the feed's rail shows for each clip: what the feed said, plus the comments the viewer posted and
/// deleted since. The feed's clips are not changed (that would restart a clip the viewer paused), so the viewer's
/// changes sit beside them and give way as soon as a feed reload says something else about the clip, because that
/// count is newer and already holds them.
struct ClipCommentCounts {
    private struct Entry {
        /// The feed's count when the viewer made the first of these changes.
        let base: Int
        /// The comments the viewer added (positive) or took away (negative) since, never below the base's worth.
        var change: Int
    }

    private var entries: [UUID: Entry] = [:]

    /// Nil while the feed does not say how many comments the clip has (a Worker from before comment counts).
    func count(for clip: FeedVideo) -> Int? {
        guard let base = clip.commentCount.map({ max(0, $0) }) else { return nil }
        guard let entry = entries[clip.id], entry.base == base else { return base }
        return base + entry.change
    }

    /// Notes that the viewer posted (+1) or deleted (-1) a comment on `clip`, as the feed has it now.
    mutating func record(_ change: Int, on clip: FeedVideo) {
        guard let shown = count(for: clip), let base = clip.commentCount.map({ max(0, $0) }) else { return }
        entries[clip.id] = Entry(base: base, change: max(0, shown + change) - base)
    }
}
