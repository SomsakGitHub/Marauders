//
//  CommentsViewModel.swift
//  Marauders
//

import Foundation
import Observation

@MainActor
@Observable
final class CommentsViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let videoID: UUID
    private(set) var state: LoadState = .idle
    /// Newest first.
    private(set) var comments: [Comment] = []
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false
    private(set) var isPosting = false
    private(set) var deletingIDs: Set<UUID> = []
    /// Why the last refresh, post or delete failed. The next action clears it.
    private(set) var errorMessage: String?
    /// What the viewer has typed in the composer.
    var draft = ""
    /// Whether the server holds comments older than the last one listed.
    private(set) var hasMore = false

    /// Bumped by every reload so a slow page from before it cannot overwrite newer rows.
    private var loadGeneration = 0
    /// True while the newest reload is in flight. The list stays on screen, but it must not grow under the refresh.
    private var isReloading = false
    /// Set when a row near the end appeared during a reload. SwiftUI reports a row only once, so the page that row
    /// asked for is fetched when the reload is over.
    private var loadMoreWaitsForReload = false
    /// Counts the posts and deletes that went through, so a reload can tell its answer predates one of them.
    private var changeCount = 0
    /// The comments the viewer deleted. A deleted comment never comes back, so an answer that still lists one was
    /// produced before the delete went through, and that row is left out.
    private var deletedIDs: Set<UUID> = []
    /// The viewer's posts whose answer arrived while the newest request of a reload was out, newest first. That
    /// request may have been served before the Worker stored them.
    private var postsDuringReload: [Comment] = []
    private let loadComments: LoadCommentsUseCase
    private let postComment: PostCommentUseCase
    private let deleteComment: DeleteCommentUseCase

    /// The next page starts loading when a row this close to the end of the list appears.
    private static let prefetchDistance = 5
    /// A reload whose answer keeps predating the viewer's own posts and deletes stops asking after this many tries.
    private static let maxReloadAttempts = 3

    init(
        videoID: UUID,
        loadComments: LoadCommentsUseCase,
        postComment: PostCommentUseCase,
        deleteComment: DeleteCommentUseCase
    ) {
        self.videoID = videoID
        self.loadComments = loadComments
        self.postComment = postComment
        self.deleteComment = deleteComment
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the composer holds text that closing the sheet would throw away.
    var hasDraft: Bool { !trimmedDraft.isEmpty }

    /// Characters left in the draft; negative once it is too long.
    var remainingCharacters: Int {
        CommentRules.maxCharacters - CommentRules.characterCount(trimmedDraft)
    }

    var isOverLimit: Bool { remainingCharacters < 0 }

    var canPost: Bool {
        state == .loaded && !isPosting && CommentRules.normalized(draft) != nil
    }

    func isDeleting(_ comment: Comment) -> Bool {
        deletingIDs.contains(comment.id)
    }

    func clearError() {
        errorMessage = nil
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    /// Loads the newest page again. A list that is already showing stays on screen while it refreshes.
    func reload() async {
        errorMessage = nil
        loadGeneration += 1
        let generation = loadGeneration
        isReloading = true
        defer {
            if generation == loadGeneration {
                isReloading = false
                loadMoreAskedDuringReload()
            }
        }
        isLoadingMore = false
        loadMoreFailed = false
        if state != .loaded { state = .loading }
        do {
            var attempts = 0
            while true {
                let changesBefore = changeCount
                postsDuringReload = []
                let page = try await loadComments.execute(videoID: videoID)
                guard generation == loadGeneration else { return }
                attempts += 1
                // A comment posted or deleted while the request was out is missing from its answer, or still in it.
                if changesBefore != changeCount, attempts < Self.maxReloadAttempts { continue }
                // The last answer is accepted as it is, so what the viewer did meanwhile is applied to it.
                let listed = page.items.filter { !deletedIDs.contains($0.id) }
                let missing = postsDuringReload.filter { post in
                    !deletedIDs.contains(post.id) && !listed.contains { $0.id == post.id }
                }
                postsDuringReload = []
                comments = missing + listed
                hasMore = page.nextCursor != nil
                state = .loaded
                return
            }
        } catch {
            guard generation == loadGeneration else { return }
            AppLog.warning("comments", "load failed: \(error.localizedDescription)")
            let message = Self.loadMessage(for: error)
            // A list emptied during the refresh while older comments exist cannot stay: "No comments yet" would be
            // wrong, and that screen has no Retry. The failed screen has one, and it loads from the newest.
            if state == .loaded, !(comments.isEmpty && hasMore) {
                errorMessage = message
            } else {
                state = .failed(message)
            }
        }
    }

    /// Called as `comment` appears; fetches the next page when it is near the end of the list.
    func loadMoreIfNeeded(currentItem comment: Comment) async {
        guard state == .loaded, !isLoadingMore, !loadMoreFailed, hasMore,
              let index = comments.firstIndex(where: { $0.id == comment.id }),
              index >= comments.count - Self.prefetchDistance
        else { return }
        if isReloading {
            loadMoreWaitsForReload = true
            return
        }
        await loadMore()
    }

    /// Runs once the newest reload is over. It is a separate task so the refresh spinner does not wait for a page
    /// the viewer did not pull for.
    private func loadMoreAskedDuringReload() {
        guard loadMoreWaitsForReload else { return }
        loadMoreWaitsForReload = false
        Task { await retryLoadMore() }
    }

    func retryLoadMore() async {
        guard state == .loaded, !isReloading, !isLoadingMore, hasMore else { return }
        await loadMore()
    }

    /// Fetches the page after the last comment on screen. The Worker's own cursor is not used: it names the last
    /// comment of the previous page, which the viewer may have deleted since, and a missing comment ends the list.
    private func loadMore(isRetry: Bool = false) async {
        guard let cursor = comments.last?.id else {
            isLoadingMore = false
            return
        }
        let generation = loadGeneration
        let deletesBefore = deletedIDs.count
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let page = try await loadComments.execute(videoID: videoID, cursor: cursor)
            guard generation == loadGeneration else { return }
            // A delete that went through while the request was out may not be in its answer yet. Ask once more,
            // after the last comment listed now.
            if deletesBefore != deletedIDs.count, !isRetry {
                await loadMore(isRetry: true)
                return
            }
            isLoadingMore = false
            if page.items.isEmpty {
                // Older comments were promised and none came: the comment this page follows has been deleted.
                // Start over from the newest, which also ends the list when nothing older is left.
                await reload()
                return
            }
            let known = Set(comments.map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) && !deletedIDs.contains($0.id) }
            comments.append(contentsOf: fresh)
            // A page that adds nothing would be asked for again, with the same cursor, for as long as its rows stay on screen.
            hasMore = page.nextCursor != nil && !fresh.isEmpty
        } catch {
            guard generation == loadGeneration else { return }
            AppLog.warning("comments", "load more failed: \(error.localizedDescription)")
            isLoadingMore = false
            loadMoreFailed = true
        }
    }

    /// Posts the draft. On success it goes to the top of the list and the draft is cleared, unless the viewer has
    /// typed something else meanwhile; on failure the draft stays so nothing the viewer typed is lost.
    func post() async {
        guard !isPosting, state == .loaded, let body = CommentRules.normalized(draft) else { return }
        let sentDraft = draft
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }
        do {
            let comment = try await postComment.execute(videoID: videoID, body: body)
            changeCount += 1
            // The viewer can refresh and delete the comment before its own answer comes back.
            if !comments.contains(where: { $0.id == comment.id }), !deletedIDs.contains(comment.id) {
                comments.insert(comment, at: 0)
            }
            if isReloading { postsDuringReload.insert(comment, at: 0) }
            if draft == sentDraft { draft = "" }
        } catch {
            errorMessage = Self.postMessage(for: error)
            AppLog.warning("comments", "post failed: \(error.localizedDescription)")
        }
    }

    /// Deletes a comment the viewer wrote or that sits on their clip.
    func delete(_ comment: Comment) async {
        guard comment.canDelete, !deletingIDs.contains(comment.id) else { return }
        deletingIDs.insert(comment.id)
        errorMessage = nil
        defer { deletingIDs.remove(comment.id) }
        do {
            try await deleteComment.execute(videoID: videoID, commentID: comment.id)
            removeFromList(comment)
        } catch CommentError.notFound {
            // Someone else already removed it; the list should say so too.
            removeFromList(comment)
        } catch {
            errorMessage = Self.deleteMessage(for: error)
            AppLog.warning("comments", "delete failed: \(error.localizedDescription)")
            return
        }
        await refillIfEmptied()
    }

    private func removeFromList(_ comment: Comment) {
        comments.removeAll { $0.id == comment.id }
        deletedIDs.insert(comment.id)
        changeCount += 1
    }

    /// Deleting every comment on screen while older ones exist would say "No comments yet"; fetch the older ones instead.
    private func refillIfEmptied() async {
        guard comments.isEmpty, hasMore, !isReloading else { return }
        state = .loading
        await reload()
    }

    private static func loadMessage(for error: Error) -> String {
        if let error = error as? CommentError, error == .notFound {
            return String(localized: "This clip is no longer available.")
        }
        return String(localized: "Couldn't load comments. Check your connection and try again.")
    }

    private static func postMessage(for error: Error) -> String {
        switch error as? CommentError {
        case .signInRequired:
            return String(localized: "Your session expired. Sign in again to comment.")
        case .notFound:
            return String(localized: "This clip is no longer available.")
        case .invalidBody:
            return String(localized: "Comments can be up to \(CommentRules.maxCharacters) characters.")
        case .rateLimited:
            return String(localized: "You're commenting too fast. Wait a moment and try again.")
        default:
            return String(localized: "Couldn't post your comment. Try again.")
        }
    }

    private static func deleteMessage(for error: Error) -> String {
        if let error = error as? CommentError, error == .signInRequired {
            return String(localized: "Your session expired. Sign in again to comment.")
        }
        return String(localized: "Couldn't delete the comment. Try again.")
    }
}
