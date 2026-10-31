//
//  CommentsView.swift
//  Marauders
//

import SwiftUI

/// A clip's comments in a bottom sheet: read them, add one, delete your own or any on your clip.
struct CommentsView: View {
    @Bindable var viewModel: CommentsViewModel
    var isSignedIn: Bool
    var onClose: () -> Void
    /// Closes the sheet so the sign-in screen can open in its place.
    var onSignIn: () -> Void
    /// The language of the viewer's country. Comments in another one open translated into it.
    var translationTarget: ListeningLanguage?

    @State private var showsOriginals = false

    @State private var pendingDeletion: Comment?
    @FocusState private var isComposing: Bool
    /// The send button grows with the text size instead of staying a fixed 34 points.
    @ScaledMetric(relativeTo: .title) private var sendIconSize: CGFloat = 34

    /// The counter shows once the draft gets this close to the limit.
    private static let counterThreshold = 50

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if case .loaded = viewModel.state, hasTranslatableComments {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(showsOriginals ? "Translate all" : "Show originals") {
                                showsOriginals.toggle()
                            }
                            .accessibilityIdentifier("comments.pageTranslation")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("comments.close")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer
                }
        }
        .accessibilityIdentifier("comments.root")
        // A stray swipe must not throw away a half-written comment; the close button still does. Once the session
        // has ended the composer is gone, and a draft nobody can see must not keep the sheet from being swiped away.
        .interactiveDismissDisabled(isSignedIn && viewModel.hasDraft)
        .task {
            await viewModel.loadIfNeeded()
        }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { comment in
            Button("Delete", role: .destructive) {
                Task { await viewModel.delete(comment) }
            }
            .accessibilityIdentifier("comments.confirmDelete")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("comments.loading")
        case .failed(let message):
            errorState(message)
        case .loaded:
            if viewModel.comments.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    /// Whether any listed comment is in another language than the viewer's: only then is there a page to translate.
    private var hasTranslatableComments: Bool {
        viewModel.comments.contains { CommentTranslation.source(for: $0, target: translationTarget) != nil }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.comments) { comment in
                    CommentRow(comment: comment, isDeleting: viewModel.isDeleting(comment),
                               translationTarget: translationTarget,
                               translatesAutomatically: !showsOriginals)
                        .id(comment.id)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if comment.canDelete {
                                Button(role: .destructive) {
                                    pendingDeletion = comment
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .accessibilityIdentifier("comments.delete")
                            }
                        }
                        .onAppear {
                            Task { await viewModel.loadMoreIfNeeded(currentItem: comment) }
                        }
                }
                footer
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await viewModel.reload()
            }
            // A comment the viewer just posted lands at the top; bring it into view.
            .onChange(of: viewModel.comments.first?.id) { _, newest in
                guard let newest else { return }
                withAnimation { proxy.scrollTo(newest, anchor: .top) }
            }
            .accessibilityIdentifier("comments.list")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if viewModel.loadMoreFailed {
            Button("Try Again") {
                Task { await viewModel.retryLoadMore() }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("comments.retryMore")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No comments yet")
                .font(.headline)
            Text("Be the first to share what you think.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comments.empty")
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("comments.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("comments.error")
            }
            if isSignedIn {
                draftField
            } else {
                Button(action: onSignIn) {
                    Text("Sign in to comment")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("comments.signIn")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .onChange(of: viewModel.errorMessage) { _, message in
            // Focus stays on the send button, so VoiceOver would otherwise never mention a failed post.
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private var draftField: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a comment…", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .focused($isComposing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background {
                        // Behind the field, so a tap on the pill's padding focuses it while a tap on the text still
                        // reaches the field itself and places the caret.
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.quaternary)
                            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .onTapGesture { isComposing = true }
                    }
                    .onChange(of: viewModel.draft) { _, _ in
                        viewModel.clearError()
                    }
                    .accessibilityIdentifier("comments.input")

                Button {
                    Task {
                        await viewModel.post()
                        if viewModel.draft.isEmpty { isComposing = false }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: sendIconSize))
                }
                .disabled(!viewModel.canPost)
                .accessibilityLabel("Post comment")
                .accessibilityIdentifier("comments.send")
            }

            if viewModel.remainingCharacters <= Self.counterThreshold {
                Text("\(viewModel.remainingCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(viewModel.isOverLimit ? Color.red : Color.secondary)
                    .padding(.trailing, 4)
                    .accessibilityLabel(counterLabel)
                    .accessibilityIdentifier("comments.counter")
            }
        }
    }

    /// Spoken in place of the bare number the counter shows.
    private var counterLabel: Text {
        viewModel.isOverLimit
            ? Text("Characters over the limit: \(-viewModel.remainingCharacters)")
            : Text("Characters left: \(viewModel.remainingCharacters)")
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }
}
