//
//  CommentRow.swift
//  Marauders
//

import SwiftUI
@preconcurrency import Translation

/// One comment: the author's avatar and handle, how long ago it was posted, and the text.
struct CommentRow: View {
    let comment: Comment
    var isDeleting = false
    /// The viewer's language. A Translate button shows when the comment is in another one.
    var translationTarget: ListeningLanguage?

    @State private var configuration: TranslationSession.Configuration?
    @State private var translatedText: String?
    @State private var showsTranslation = false
    @State private var isTranslating = false
    @State private var translationFailed = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // "now" rather than "in 0 sec." for a comment posted this very moment.
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private var sourceCode: String? {
        CommentTranslation.sourceCode(for: comment, target: translationTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            commentContent
            translationControls
        }
        .padding(.vertical, 4)
        .opacity(isDeleting ? 0.4 : 1)
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(comment.body)
                await MainActor.run {
                    translatedText = response.targetText
                    showsTranslation = true
                    isTranslating = false
                }
            } catch {
                await MainActor.run {
                    // A cancelled request (the row left the screen) is not a failure the viewer needs to hear about.
                    translationFailed = !Task.isCancelled
                    isTranslating = false
                }
            }
        }
    }

    private var commentContent: some View {
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
                Text(showsTranslation ? (translatedText ?? comment.body) : comment.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comments.row")
    }

    /// Lines up with the comment text, to the right of the avatar.
    @ViewBuilder
    private var translationControls: some View {
        if let sourceCode, let translationTarget {
            Group {
                if isTranslating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("comments.translating")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Button(showsTranslation ? "Show original" : "Translate") {
                            if showsTranslation {
                                showsTranslation = false
                            } else if translatedText != nil {
                                showsTranslation = true
                            } else {
                                startTranslation(from: sourceCode, to: translationTarget)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("comments.translate")
                        if showsTranslation {
                            Text("Translated on this iPhone from \(sourceName(sourceCode))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if translationFailed {
                            Text("Couldn't translate this comment.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("comments.translateFailed")
                        }
                    }
                }
            }
            .padding(.leading, 46)
        }
    }

    private func startTranslation(from sourceCode: String, to target: ListeningLanguage) {
        translationFailed = false
        isTranslating = true
        let next = TranslationSession.Configuration(source: .init(identifier: sourceCode), target: .init(identifier: target.code))
        // Invalidating makes a retry after a failure run again although the configuration is the same.
        configuration = next
        configuration?.invalidate()
    }

    private func sourceName(_ code: String) -> String {
        ListeningLanguage(identifier: code)?.displayName() ?? code
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
