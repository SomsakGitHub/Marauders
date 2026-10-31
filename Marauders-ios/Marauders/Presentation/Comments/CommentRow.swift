//
//  CommentRow.swift
//  Marauders
//

import SwiftUI

/// One comment: the author's avatar and handle, how long ago it was posted, and the text.
struct CommentRow: View {
    let comment: Comment
    var isDeleting = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // "now" rather than "in 0 sec." for a comment posted this very moment.
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.authorAvatarURL, handle: comment.authorName, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                // Handle and time share a line while they fit; at large text sizes the time drops below the handle,
                // so neither one is cut short.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        handle
                        time
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        handle
                        time
                    }
                }
                Text(comment.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(isDeleting ? 0.4 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comments.row")
    }

    private var handle: some View {
        Text(comment.authorName ?? String(localized: "Unknown user"))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
    }

    private var time: some View {
        Text(relativeTime)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// Never in the future, even when the phone's clock runs behind the server's.
    private var relativeTime: String {
        let now = Date()
        return Self.relativeFormatter.localizedString(for: min(comment.createdAt, now), relativeTo: now)
    }
}
