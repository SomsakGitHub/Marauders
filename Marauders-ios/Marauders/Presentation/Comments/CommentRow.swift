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
    /// The page is translated: show this comment in the viewer's language, translating it the first time.
    var translatesAutomatically = false

    @State private var configuration: TranslationSession.Configuration?
    @State private var translatedText: String?
    @State private var showsTranslation = false
    @State private var isTranslating = false
    @State private var translationFailed = false
    /// Whether the translation on its way should be shown when it lands; showing the originals meanwhile cancels that.
    @State private var showsWhenTranslated = false
    /// The language Apple Translation says it translated from, which it works out itself for a short comment.
    @State private var translatedFrom: Locale.Language?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // "now" rather than "in 0 sec." for a comment posted this very moment.
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private var source: CommentTranslation.Source? {
        CommentTranslation.source(for: comment, target: translationTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            commentContent
            translationControls
        }
        .padding(.vertical, 4)
        .opacity(isDeleting ? 0.4 : 1)
        .onChange(of: translatesAutomatically, initial: true) { _, translates in
            followPage(translates)
        }
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(comment.body)
                await MainActor.run {
                    translatedText = response.targetText
                    translatedFrom = response.sourceLanguage
                    showsTranslation = showsWhenTranslated
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
        if let source, let translationTarget {
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
                                startTranslation(from: source, to: translationTarget)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("comments.translate")
                        if showsTranslation {
                            Text("Translated on this iPhone from \(sourceName)")
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

    /// The page switch wins over this row's own button: translating the page shows every translation, and showing
    /// the originals hides them. A translation already made is shown again without asking Apple Translation twice.
    private func followPage(_ translates: Bool) {
        guard translates else {
            showsTranslation = false
            showsWhenTranslated = false
            return
        }
        guard let source, let translationTarget else { return }
        if translatedText != nil {
            showsTranslation = true
        } else if !isTranslating {
            startTranslation(from: source, to: translationTarget)
        }
    }

    private func startTranslation(from source: CommentTranslation.Source, to target: ListeningLanguage) {
        translationFailed = false
        isTranslating = true
        showsWhenTranslated = true
        let sourceLanguage: Locale.Language? = switch source {
        case .known(let code): Locale.Language(identifier: code)
        case .detectedByTranslation: nil
        }
        let next = TranslationSession.Configuration(source: sourceLanguage, target: .init(identifier: target.code))
        // Invalidating makes a retry after a failure run again although the configuration is the same.
        configuration = next
        configuration?.invalidate()
    }

    private var sourceName: String {
        let code = translatedFrom?.minimalIdentifier ?? {
            if case .known(let code) = source { return code }
            return ""
        }()
        return ListeningLanguage(identifier: code)?.displayName()
            ?? ListeningLanguage.interfaceLocale.localizedString(forIdentifier: code)
            ?? code
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
