//
//  CommentsViewModelTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

// Swift Testing declares its own `Comment`; this keeps the name pointing at the app's.
private typealias Comment = Marauders.Comment

@MainActor
struct CommentsViewModelTests {
    private static let videoID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func makeSUT(
        fetchResults: [Result<CommentPage, Error>] = [.success(CommentPage(items: [], nextCursor: nil))]
    ) -> (CommentsViewModel, StubCommentRepository) {
        let repository = StubCommentRepository(fetchResults: fetchResults)
        let viewModel = CommentsViewModel(
            videoID: Self.videoID,
            loadComments: LoadCommentsUseCase(repository: repository),
            postComment: PostCommentUseCase(repository: repository),
            deleteComment: DeleteCommentUseCase(repository: repository)
        )
        return (viewModel, repository)
    }

    private func comment(_ body: String, canDelete: Bool = false) -> Comment {
        Comment(body: body, authorName: "@someone", canDelete: canDelete)
    }

    private func comments(count: Int) -> [Comment] {
        (0 ..< count).map { comment("c\($0)") }
    }

    private func loadedSUT(
        _ items: [Comment],
        nextCursor: UUID? = nil
    ) async -> (CommentsViewModel, StubCommentRepository) {
        let (viewModel, repository) = makeSUT(fetchResults: [.success(CommentPage(items: items, nextCursor: nextCursor))])
        await viewModel.loadIfNeeded()
        return (viewModel, repository)
    }

    /// Waits, for up to two seconds, for work the view model starts as a task of its own.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Gives such a task time to show itself when the test expects there is none.
    private func letBackgroundWorkRun() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Loading

    @Test func loadShowsTheFirstPage() async {
        let page = CommentPage(items: [comment("one"), comment("two")], nextCursor: nil)
        let (viewModel, repository) = makeSUT(fetchResults: [.success(page)])

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.comments == page.items)
        #expect(viewModel.hasMore == false)
        #expect(repository.fetches.count == 1)
        #expect(repository.fetches.first?.videoID == Self.videoID)
        #expect(repository.fetches.first?.cursor == nil)
        #expect(repository.fetches.first?.limit == CommentRules.pageSize)
    }

    @Test func aClipWithoutCommentsLoadsAsEmpty() async {
        let (viewModel, _) = await loadedSUT([])

        #expect(viewModel.state == .loaded)
        #expect(viewModel.comments.isEmpty)
    }

    @Test func loadIfNeededOnlyLoadsOnce() async {
        let (viewModel, repository) = await loadedSUT([comment("one")])

        await viewModel.loadIfNeeded()

        #expect(repository.fetches.count == 1)
    }

    @Test func reloadReplacesTheListWithTheNewestPage() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [comment("old")], nextCursor: nil)),
            .success(CommentPage(items: [comment("new"), comment("old")], nextCursor: nil)),
        ])

        await viewModel.loadIfNeeded()
        await viewModel.reload()

        #expect(repository.fetches.count == 2)
        #expect(repository.fetches.last?.cursor == nil)
        #expect(viewModel.comments.map(\.body) == ["new", "old"])
    }

    @Test func loadFailureExposesAMessage() async {
        let (viewModel, _) = makeSUT(fetchResults: [.failure(StubError.feedFailed)])

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .failed(String(localized: "Couldn't load comments. Check your connection and try again.")))
        #expect(viewModel.comments.isEmpty)
    }

    @Test func aFailedLoadCanBeRetried() async {
        let (viewModel, _) = makeSUT(fetchResults: [
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [comment("back")], nextCursor: nil)),
        ])

        await viewModel.loadIfNeeded()
        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.comments.map(\.body) == ["back"])
    }

    @Test func retryShowsTheSpinnerWhileTheRequestIsOut() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [comment("back")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        #expect(viewModel.state == .failed(String(localized: "Couldn't load comments. Check your connection and try again.")))
        let sawLoading = Flag()
        repository.beforeFetchReturns = { [viewModel] in
            sawLoading.value = await MainActor.run { viewModel.state == .loading }
        }

        await viewModel.reload()

        #expect(sawLoading.value)
        #expect(viewModel.state == .loaded)
    }

    @Test func loadingACommentThreadOfAMissingClipSaysSo() async {
        let (viewModel, _) = makeSUT(fetchResults: [.failure(CommentError.notFound)])

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .failed(String(localized: "This clip is no longer available.")))
    }

    @Test func aFailedRefreshKeepsTheListAndShowsAMessage() async {
        let (viewModel, _) = makeSUT(fetchResults: [
            .success(CommentPage(items: [comment("kept")], nextCursor: nil)),
            .failure(StubError.feedFailed),
        ])

        await viewModel.loadIfNeeded()
        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.comments.map(\.body) == ["kept"])
        #expect(viewModel.errorMessage == String(localized: "Couldn't load comments. Check your connection and try again."))
    }

    @Test func aFailedRefreshOfAListEmptiedMeanwhileKeepsItWhenNothingOlderExists() async {
        let only = comment("only", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [only], nextCursor: nil)),
            .failure(StubError.feedFailed),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The viewer deletes the only comment while the refresh is on its way.
            await viewModel.delete(only)
        }

        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.comments.isEmpty)
        #expect(viewModel.errorMessage == String(localized: "Couldn't load comments. Check your connection and try again."))
    }

    @Test func aFailedRefreshAfterTheLastListedCommentWasDeletedOffersARetry() async {
        let only = comment("only", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [only], nextCursor: only.id)),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // Older comments exist, but the refill waits for the refresh, and the refresh fails.
            await viewModel.delete(only)
        }

        await viewModel.reload()

        // "No comments yet" would be wrong here and has no Retry button; the failed screen has one.
        #expect(viewModel.state == .failed(String(localized: "Couldn't load comments. Check your connection and try again.")))
        #expect(viewModel.comments.isEmpty)
        // That screen already says it, so the composer's message line stays empty.
        #expect(viewModel.errorMessage == nil)

        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.comments.map(\.body) == ["older"])
    }

    @Test func aRefreshThatRacedTheLastDeleteAndWasAskedAgainOffersARetryWhenThatFails() async {
        let only = comment("only", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [only], nextCursor: only.id)),
            // This answer cannot know about the delete, so the view model asks again, and that request fails.
            .success(CommentPage(items: [only], nextCursor: only.id)),
            .failure(StubError.feedFailed),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.delete(only)
        }

        await viewModel.reload()

        #expect(viewModel.state == .failed(String(localized: "Couldn't load comments. Check your connection and try again.")))
        #expect(viewModel.comments.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(repository.fetches.count == 3)
    }

    @Test func aSuccessfulRefreshClearsAnEarlierErrorMessage() async {
        let (viewModel, _) = makeSUT(fetchResults: [
            .success(CommentPage(items: [comment("kept")], nextCursor: nil)),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [comment("fresh")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        await viewModel.reload()
        #expect(viewModel.errorMessage != nil)

        await viewModel.reload()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.comments.map(\.body) == ["fresh"])
    }

    @Test func aPostFailureThatLandsDuringARefreshStaysVisible() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [comment("old")], nextCursor: nil)),
            .success(CommentPage(items: [comment("old")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        repository.postResult = .failure(CommentError.rateLimited)
        viewModel.draft = "Hello"
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.post()
        }

        await viewModel.reload()

        #expect(viewModel.errorMessage == String(localized: "You're commenting too fast. Wait a moment and try again."))
    }

    @Test func aSlowEarlierLoadCannotOverwriteANewerOne() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [comment("stale")], nextCursor: nil)),
            .success(CommentPage(items: [comment("fresh")], nextCursor: nil)),
        ])
        let interleave = OneShot()
        // While the first (stale) page is still on its way, a second reload starts and finishes.
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.reload()
        }

        await viewModel.reload()

        #expect(viewModel.comments.map(\.body) == ["fresh"])
        #expect(viewModel.state == .loaded)
    }

    @Test func aFailedRefreshFromBeforeANewerOneLeavesNoMessage() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [comment("kept")], nextCursor: nil)),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [comment("fresh")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // A newer refresh starts and finishes while the first one is still on its way; then the first one fails.
            await viewModel.reload()
        }

        await viewModel.reload()

        #expect(viewModel.comments.map(\.body) == ["fresh"])
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.state == .loaded)
    }

    // MARK: - Paging

    @Test func scrollingNearTheEndLoadsTheNextPage() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        #expect(viewModel.hasMore)

        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        #expect(repository.fetches.count == 2)
        // The next page starts after the last comment on screen.
        #expect(repository.fetches.last?.cursor == first[11].id)
        #expect(viewModel.comments.count == 13)
        #expect(viewModel.comments.last?.body == "older")
        #expect(viewModel.hasMore == false)
        #expect(viewModel.isLoadingMore == false)
    }

    @Test func rowsFarFromTheEndDoNotLoadMore() async {
        let first = comments(count: 12)
        let (viewModel, repository) = await loadedSUT(first, nextCursor: UUID())

        await viewModel.loadMoreIfNeeded(currentItem: first[0])

        #expect(repository.fetches.count == 1)
    }

    @Test func theNextPageStartsLoadingFiveRowsBeforeTheEnd() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.loadMoreIfNeeded(currentItem: first[6])
        #expect(repository.fetches.count == 1)

        await viewModel.loadMoreIfNeeded(currentItem: first[7])
        #expect(repository.fetches.count == 2)
    }

    @Test func theLastPageStopsPaging() async {
        let first = comments(count: 12)
        let (viewModel, repository) = await loadedSUT(first, nextCursor: nil)

        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        #expect(repository.fetches.count == 1)
    }

    @Test func aCommentRepeatedByTheNextPageIsNotListedTwice() async {
        let first = comments(count: 6)
        let (viewModel, _) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [first[5], comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.loadMoreIfNeeded(currentItem: first[5])

        #expect(viewModel.comments.map(\.body) == ["c0", "c1", "c2", "c3", "c4", "c5", "older"])
    }

    @Test func aFailedPageWaitsForARetryInsteadOfLooping() async throws {
        let first = comments(count: 6)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.loadMoreIfNeeded(currentItem: first[5])
        #expect(viewModel.loadMoreFailed)
        #expect(viewModel.comments.count == 6)

        // Rows scrolling into view again must not hammer a failing server.
        await viewModel.loadMoreIfNeeded(currentItem: first[5])
        #expect(repository.fetches.count == 2)

        await viewModel.retryLoadMore()
        #expect(viewModel.loadMoreFailed == false)
        #expect(viewModel.comments.last?.body == "older")
        try #require(repository.fetches.count == 3)
        // The retry asks for the very page that failed.
        #expect(repository.fetches[1].cursor == first[5].id)
        #expect(repository.fetches[2].cursor == repository.fetches[1].cursor)
    }

    @Test func pagingContinuesAfterTheLastListedCommentWasDeleted() async {
        let mine = comment("mine", canDelete: true)
        let first = comments(count: 5) + [mine]
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: mine.id)),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        await viewModel.delete(mine)

        await viewModel.loadMoreIfNeeded(currentItem: first[4])

        // The Worker cannot continue from a comment that no longer exists, so the page starts after one still listed.
        #expect(repository.fetches.last?.cursor == first[4].id)
        #expect(viewModel.comments.last?.body == "older")
    }

    @Test func deletingEveryListedCommentLoadsTheOlderOnes() async {
        let only = comment("only", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [only], nextCursor: only.id)),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.delete(only)

        #expect(repository.fetches.count == 2)
        #expect(repository.fetches.last?.cursor == nil)
        #expect(viewModel.comments.map(\.body) == ["older"])
        #expect(viewModel.state == .loaded)
    }

    @Test func emptyingTheLastPageDoesNotAskForMore() async {
        let only = comment("only", canDelete: true)
        let (viewModel, repository) = await loadedSUT([only], nextCursor: nil)

        await viewModel.delete(only)

        #expect(viewModel.comments.isEmpty)
        #expect(viewModel.state == .loaded)
        #expect(repository.fetches.count == 1)
    }

    @Test func aFailedRefetchAfterEmptyingTheListOffersARetryInsteadOfNoComments() async {
        let only = comment("only", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [only], nextCursor: only.id)),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.delete(only)

        #expect(viewModel.state == .failed(String(localized: "Couldn't load comments. Check your connection and try again.")))
        #expect(viewModel.comments.isEmpty)

        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.comments.map(\.body) == ["older"])
        #expect(repository.fetches.count == 3)
    }

    @Test func aPageWithNothingNewEndsPagingInsteadOfAskingAgain() async {
        let first = comments(count: 6)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [first[5]], nextCursor: UUID())),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.loadMoreIfNeeded(currentItem: first[5])
        #expect(viewModel.hasMore == false)
        #expect(viewModel.comments.count == 6)

        await viewModel.loadMoreIfNeeded(currentItem: first[5])
        #expect(repository.fetches.count == 2)
    }

    @Test func anEmptyPageAfterACursorStartsOverFromTheNewest() async throws {
        let first = comments(count: 6)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: first[5].id)),
            // The comment this page should follow was deleted by someone else, which the Worker answers with nothing.
            .success(CommentPage(items: [], nextCursor: nil)),
            .success(CommentPage(items: [comment("new")] + first, nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.loadMoreIfNeeded(currentItem: first[5])

        try #require(repository.fetches.count == 3)
        #expect(repository.fetches[1].cursor == first[5].id)
        #expect(repository.fetches[2].cursor == nil)
        #expect(viewModel.comments.map(\.body) == ["new", "c0", "c1", "c2", "c3", "c4", "c5"])
        #expect(viewModel.hasMore == false)
        #expect(viewModel.isLoadingMore == false)
        #expect(viewModel.state == .loaded)
    }

    @Test func startingOverEndsPagingWhenNothingOlderIsLeft() async {
        let first = comments(count: 6)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: first[5].id)),
            .success(CommentPage(items: [], nextCursor: nil)),
            .success(CommentPage(items: first, nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        await viewModel.loadMoreIfNeeded(currentItem: first[5])

        await viewModel.loadMoreIfNeeded(currentItem: first[5])

        #expect(repository.fetches.count == 3)
        #expect(viewModel.hasMore == false)
        #expect(viewModel.comments == first)
    }

    @Test func aPageRequestedBeforeARefreshCannotAppendAfterIt() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
            .success(CommentPage(items: first, nextCursor: UUID())),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The refresh starts and finishes while the page request is still on its way.
            await viewModel.reload()
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        #expect(viewModel.comments == first)
        #expect(viewModel.isLoadingMore == false)
        #expect(viewModel.hasMore)
    }

    @Test func aFailedPageRequestedBeforeARefreshDoesNotMarkTheFreshListAsFailed() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: first, nextCursor: UUID())),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The refresh starts and finishes while the page request is still on its way; then the page fails.
            await viewModel.reload()
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        #expect(viewModel.loadMoreFailed == false)
        #expect(viewModel.isLoadingMore == false)
        #expect(viewModel.comments == first)
    }

    @Test func aSecondRowNearTheEndWhileAPageLoadsDoesNotAskAgain() async {
        let first = comments(count: 12)
        let older = (0 ..< 3).map { comment("older\($0)") }
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: older, nextCursor: UUID())),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The row above scrolls into view before the page the last row asked for has arrived.
            await viewModel.loadMoreIfNeeded(currentItem: first[10])
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        #expect(repository.fetches.count == 2)
        #expect(viewModel.comments == first + older)
        #expect(viewModel.hasMore)
    }

    @Test func deletingTheLastRowWhileAPageLoadsStillReloadsFromTheNewest() async {
        let only = comment("only", canDelete: true)
        let newest = comments(count: 3)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [only], nextCursor: UUID())),
            .success(CommentPage(items: [comment("stale")], nextCursor: nil)),
            .success(CommentPage(items: newest, nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The only comment listed is deleted while the page after it is on its way.
            await viewModel.delete(only)
        }

        await viewModel.loadMoreIfNeeded(currentItem: only)

        // That page followed a comment that is gone, so it must not become the whole list.
        #expect(viewModel.comments == newest)
        #expect(viewModel.state == .loaded)
        #expect(viewModel.isLoadingMore == false)
        // The page answer is stale once the list starts over, so it is dropped rather than asked for again.
        #expect(repository.fetches.count == 3)
    }

    @Test func aSlowPageAnswerDoesNotBringBackACommentTheViewerDeleted() async {
        let first = comments(count: 6)
        let doomed = comment("doomed", canDelete: true)
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            // Served before the Worker processed the delete, so it still lists the comment.
            .success(CommentPage(items: [doomed, older], nextCursor: nil)),
            .success(CommentPage(items: [older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The answer to the viewer's delete of `doomed` arrives while this page request is still out.
            await viewModel.delete(doomed)
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[5])

        #expect(viewModel.comments == first + [older])
        #expect(viewModel.isLoadingMore == false)
        #expect(viewModel.hasMore == false)
    }

    @Test func aPageAskedAgainStillLeavesOutWhatTheViewerDeletedMeanwhile() async {
        let first = comments(count: 6)
        let other = comment("other", canDelete: true)
        let doomed = comment("doomed", canDelete: true)
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            // Both answers were served before the Worker processed the delete that goes through meanwhile.
            .success(CommentPage(items: [other, older], nextCursor: nil)),
            .success(CommentPage(items: [doomed, older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let calls = Counter()
        repository.beforeFetchReturns = { [viewModel] in
            switch calls.next() {
            case 1: await viewModel.delete(other)
            case 2: await viewModel.delete(doomed)
            default: break
            }
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[5])

        #expect(repository.fetches.count == 3)
        #expect(viewModel.comments == first + [older])
        #expect(viewModel.isLoadingMore == false)
        #expect(viewModel.hasMore == false)
    }

    @Test func aPageThatKeepsOverlappingDeletesIsAskedOnceMoreAndNoMore() async {
        let first = (0 ..< 12).map { comment("c\($0)", canDelete: true) }
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let calls = Counter()
        repository.beforeFetchReturns = { [viewModel] in
            let call = calls.next()
            guard call <= 4 else { return }
            // A different comment is deleted while each request is out.
            await viewModel.delete(first[call])
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        // The second answer is taken as it is, however many deletes overlapped it.
        #expect(repository.fetches.count == 3)
        #expect(viewModel.comments == [first[0]] + first[3...] + [older])
        #expect(viewModel.isLoadingMore == false)
    }

    @Test func deletingTheLastListedCommentWhileItsPageIsOutAsksAgainAfterTheNewLastOne() async throws {
        let mine = comment("mine", canDelete: true)
        let first = comments(count: 5) + [mine]
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: mine.id)),
            // Served after the Worker processed the delete: the comment this page follows is gone, so nothing comes back.
            .success(CommentPage(items: [], nextCursor: nil)),
            .success(CommentPage(items: [older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.delete(mine)
        }

        await viewModel.loadMoreIfNeeded(currentItem: mine)

        try #require(repository.fetches.count == 3)
        #expect(repository.fetches[1].cursor == mine.id)
        #expect(repository.fetches[2].cursor == first[4].id)
        #expect(viewModel.comments == Array(first.dropLast()) + [older])
    }

    @Test func aPostWhileAPageIsOutDoesNotMakeItAskAgain() async {
        let first = comments(count: 12)
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await MainActor.run { viewModel.draft = "Hello" }
            await viewModel.post()
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        // A post lands on top of the list, so a page of older comments cannot be missing it.
        #expect(repository.posts.count == 1)
        #expect(repository.fetches.count == 2)
        #expect(viewModel.comments.map(\.body) == ["Hello"] + first.map(\.body) + ["older"])
    }

    // MARK: - Refreshing while other things happen

    @Test func loadingMoreDoesNotStartWhileTheListRefreshes() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // A row near the end scrolls into view while the refresh is still on its way.
            await viewModel.loadMoreIfNeeded(currentItem: first[11])
            await viewModel.retryLoadMore()
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 2)
        #expect(viewModel.comments.count == 12)
        #expect(viewModel.isLoadingMore == false)
    }

    @Test func aRowNearTheEndThatAppearedDuringARefreshLoadsItsPageOnceTheRefreshIsOver() async {
        let first = comments(count: 12)
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The row scrolls into view while the refresh is on its way, and SwiftUI will not report it again.
            await viewModel.loadMoreIfNeeded(currentItem: first[11])
        }

        await viewModel.reload()
        await waitUntil { repository.fetches.count == 3 && !viewModel.isLoadingMore }

        #expect(repository.fetches.count == 3)
        #expect(repository.fetches.last?.cursor == first[11].id)
        #expect(viewModel.comments == first + [older])
        #expect(viewModel.hasMore == false)
    }

    @Test func aRefreshThatFindsNewCommentsContinuesAfterTheLastCommentNowListed() async {
        let first = comments(count: 12)
        let newest = comment("new")
        let refreshed = [newest] + first.prefix(11)
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: refreshed, nextCursor: UUID())),
            .success(CommentPage(items: [first[11], older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.loadMoreIfNeeded(currentItem: first[11])
        }

        await viewModel.reload()
        await waitUntil { repository.fetches.count == 3 && !viewModel.isLoadingMore }

        // The row pushed off the first page by the new comment is the next one listed, not skipped.
        #expect(repository.fetches.last?.cursor == first[10].id)
        #expect(viewModel.comments == refreshed + [first[11], older])
    }

    @Test func aRefreshThatFailedStillLoadsThePageARowAskedForMeanwhile() async {
        let first = comments(count: 12)
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: [older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.loadMoreIfNeeded(currentItem: first[11])
        }

        await viewModel.reload()
        await waitUntil { repository.fetches.count == 3 && !viewModel.isLoadingMore }

        #expect(viewModel.comments == first + [older])
        #expect(viewModel.errorMessage == String(localized: "Couldn't load comments. Check your connection and try again."))
    }

    @Test func aRefreshThatEndsTheListDoesNotAskForAnotherPage() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.loadMoreIfNeeded(currentItem: first[11])
        }

        await viewModel.reload()
        await letBackgroundWorkRun()

        #expect(repository.fetches.count == 2)
        #expect(viewModel.hasMore == false)
    }

    @Test func aRefreshWithNoRowNearTheEndFetchesNothingElse() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [comment("older")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()

        await viewModel.reload()
        await letBackgroundWorkRun()

        #expect(repository.fetches.count == 2)
        #expect(viewModel.comments == first)
    }

    @Test func aRefreshThatRacedAPostAsksAgain() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [comment("old")], nextCursor: nil)),
            .success(CommentPage(items: [comment("old")], nextCursor: nil)),
            .success(CommentPage(items: [comment("Hello"), comment("old")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            // The post goes through while the refresh answer, which cannot show it, is still on its way.
            await MainActor.run { viewModel.draft = "Hello" }
            await viewModel.post()
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 3)
        #expect(viewModel.comments.map(\.body) == ["Hello", "old"])
    }

    @Test func aRefreshThatRacedADeleteAsksAgain() async {
        let mine = comment("mine", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [mine, comment("other")], nextCursor: nil)),
            .success(CommentPage(items: [mine, comment("other")], nextCursor: nil)),
            .success(CommentPage(items: [comment("other")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.delete(mine)
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 3)
        #expect(viewModel.comments.map(\.body) == ["other"])
    }

    @Test func aRefreshThatKeepsRacingNewPostsStopsAskingAfterThreeRequests() async {
        let (viewModel, repository) = makeSUT(fetchResults: [.success(CommentPage(items: [comment("old")], nextCursor: nil))])
        await viewModel.loadIfNeeded()
        let calls = Counter()
        repository.beforeFetchReturns = { [viewModel] in
            // Every answer to the refresh finds that the viewer has just posted again. The race ends after a few
            // requests, so a missing bound fails the expectations below instead of looping for ever.
            guard calls.next() <= 8 else { return }
            await MainActor.run { viewModel.draft = "again" }
            await viewModel.post()
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 1 + 3)
        #expect(viewModel.state == .loaded)
        #expect(viewModel.isPosting == false)
    }

    /// The third request of a refresh is the last one: its answer is accepted although the viewer's third post went
    /// through while it was out, and the answer may or may not list that post already.
    private func racingPostsSUT(
        lastAnswerListsThePost: Bool
    ) async -> (CommentsViewModel, StubCommentRepository, posted: [Comment], old: Comment) {
        let old = comment("old")
        let posted = (1 ... 3).map { comment("post \($0)", canDelete: true) }
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [old], nextCursor: nil)),
            .success(CommentPage(items: [old], nextCursor: nil)),
            .success(CommentPage(items: [posted[0], old], nextCursor: nil)),
            .success(CommentPage(
                items: lastAnswerListsThePost ? [posted[2], posted[1], posted[0], old] : [posted[1], posted[0], old],
                nextCursor: nil
            )),
        ])
        await viewModel.loadIfNeeded()
        return (viewModel, repository, posted, old)
    }

    @Test(arguments: [false, true])
    func aRefreshThatKeepsRacingNewPostsStillShowsTheLastPost(lastAnswerListsThePost: Bool) async {
        let (viewModel, repository, posted, old) = await racingPostsSUT(lastAnswerListsThePost: lastAnswerListsThePost)
        let calls = Counter()
        repository.beforeFetchReturns = { [viewModel, repository] in
            let call = calls.next()
            guard call <= posted.count else { return }
            repository.postResult = .success(posted[call - 1])
            await MainActor.run { viewModel.draft = "post \(call)" }
            await viewModel.post()
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 1 + 3)
        #expect(viewModel.comments == [posted[2], posted[1], posted[0], old])
    }

    @Test func aPostDeletedWhileTheLastRequestOfARefreshWasOutStaysGone() async {
        let (viewModel, repository, posted, old) = await racingPostsSUT(lastAnswerListsThePost: false)
        let calls = Counter()
        repository.beforeFetchReturns = { [viewModel, repository] in
            let call = calls.next()
            guard call <= posted.count else { return }
            repository.postResult = .success(posted[call - 1])
            await MainActor.run { viewModel.draft = "post \(call)" }
            await viewModel.post()
            if call == posted.count { await viewModel.delete(posted[call - 1]) }
        }

        await viewModel.reload()

        #expect(viewModel.comments == [posted[1], posted[0], old])
    }

    @Test func aPostTheNewestRequestNoLongerListsDoesNotComeBackFromAnEarlierRequest() async {
        let old = comment("old")
        let mine = comment("mine", canDelete: true)
        // The first request was served before the post; the owner of the clip removed the post before the second.
        let (viewModel, repository) = makeSUT(fetchResults: [.success(CommentPage(items: [old], nextCursor: nil))])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel, repository] in
            guard interleave.claim() else { return }
            repository.postResult = .success(mine)
            await MainActor.run { viewModel.draft = "mine" }
            await viewModel.post()
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 1 + 2)
        #expect(viewModel.comments == [old])
    }

    @Test func aRefreshThatKeepsRacingDeletesStillLeavesOutWhatTheViewerDeleted() async {
        let doomed = (0 ..< 3).map { comment("doomed\($0)", canDelete: true) }
        let kept = comment("kept")
        let (viewModel, repository) = makeSUT(fetchResults: [.success(CommentPage(items: doomed + [kept], nextCursor: nil))])
        await viewModel.loadIfNeeded()
        let calls = Counter()
        repository.beforeFetchReturns = { [viewModel] in
            // Every answer was served before the Worker processed the delete that goes through meanwhile, so each
            // still lists comments that are gone. The last one is accepted after the third request.
            let call = calls.next()
            guard call <= doomed.count else { return }
            await viewModel.delete(doomed[call - 1])
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 1 + 3)
        #expect(viewModel.comments == [kept])
        #expect(viewModel.state == .loaded)
    }

    @Test func aRefreshClearsAFailedPageMarker() async {
        let first = comments(count: 12)
        let (viewModel, _) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .failure(StubError.feedFailed),
            .success(CommentPage(items: first, nextCursor: UUID())),
        ])
        await viewModel.loadIfNeeded()
        await viewModel.loadMoreIfNeeded(currentItem: first[11])
        #expect(viewModel.loadMoreFailed)

        await viewModel.reload()

        #expect(viewModel.loadMoreFailed == false)
    }

    @Test func aRowThatAskedDuringOneRefreshDoesNotMakeTheNextRefreshLoadAPage() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [comment("older")], nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            // Only a flag left over from the first refresh would ask for this one.
            .success(CommentPage(items: [comment("other")], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let interleave = OneShot()
        repository.beforeFetchReturns = { [viewModel] in
            guard interleave.claim() else { return }
            await viewModel.loadMoreIfNeeded(currentItem: first[11])
        }
        await viewModel.reload()
        await waitUntil { repository.fetches.count == 3 && !viewModel.isLoadingMore }
        #expect(repository.fetches.count == 3)

        await viewModel.reload()
        await letBackgroundWorkRun()

        #expect(repository.fetches.count == 4)
        #expect(viewModel.comments == first)
    }

    @Test func aQueuedPageRequestDoesNotDuplicateOneThatIsAlreadyOut() async {
        let first = comments(count: 12)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [comment("older")], nextCursor: UUID())),
        ])
        await viewModel.loadIfNeeded()
        let calls = Counter()
        repository.beforeFetchReturns = { [viewModel] in
            switch calls.next() {
            case 1:
                // A row near the end appears while the refresh is out, so the page waits for the refresh.
                await viewModel.loadMoreIfNeeded(currentItem: first[11])
            case 2:
                // The page request stays out for a while.
                try? await Task.sleep(for: .milliseconds(60))
            default:
                return
            }
        }

        await viewModel.reload()
        // The refresh is over and the page it queued is about to start; the row is reported again first.
        await viewModel.loadMoreIfNeeded(currentItem: first[11])
        await letBackgroundWorkRun()

        #expect(repository.fetches.count == 3)
    }

    @Test func aRowNearTheEndStillWaitsWhenAnOlderRefreshEndsBeforeTheNewestOne() async {
        let first = comments(count: 12)
        let older = comment("older")
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: first, nextCursor: UUID())),
            .success(CommentPage(items: [older], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        let calls = Counter()
        let newestHasStarted = Flag()
        let newestMayEnd = Flag()
        repository.beforeFetchReturns = { [viewModel] in
            switch calls.next() {
            case 1:
                // A newer refresh starts while this one is out; this one ends first and is dropped.
                Task { await viewModel.reload() }
                for _ in 0 ..< 200 where !newestHasStarted.value {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            case 2:
                // The newest refresh stays out until the test lets it end.
                newestHasStarted.value = true
                for _ in 0 ..< 200 where !newestMayEnd.value {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            default:
                return
            }
        }

        await viewModel.reload()
        let fetchesWhileTheNewestIsOut = repository.fetches.count
        await viewModel.loadMoreIfNeeded(currentItem: first[11])

        #expect(fetchesWhileTheNewestIsOut == 3)
        #expect(repository.fetches.count == fetchesWhileTheNewestIsOut)

        newestMayEnd.value = true
        await waitUntil { repository.fetches.count == 4 && !viewModel.isLoadingMore }

        #expect(repository.fetches.count == 4)
        #expect(viewModel.comments == first + [older])
    }

    // MARK: - Posting

    @Test func postingAddsTheCommentAtTheTopAndClearsTheDraft() async {
        let (viewModel, repository) = await loadedSUT([comment("old")])
        viewModel.draft = "  Hello there \n"

        await viewModel.post()

        #expect(repository.posts.count == 1)
        #expect(repository.posts.first?.videoID == Self.videoID)
        #expect(repository.posts.first?.body == "Hello there")
        #expect(repository.posts.first?.language == nil)
        #expect(viewModel.comments.map(\.body) == ["Hello there", "old"])
        #expect(viewModel.draft.isEmpty)
        #expect(viewModel.isPosting == false)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func aFailedPostKeepsTheDraftAndExplainsWhy() async {
        let (viewModel, repository) = await loadedSUT([comment("old")])
        repository.postResult = .failure(CommentError.rateLimited)
        viewModel.draft = "Hello"

        await viewModel.post()

        #expect(viewModel.draft == "Hello")
        #expect(viewModel.comments.map(\.body) == ["old"])
        #expect(viewModel.errorMessage == String(localized: "You're commenting too fast. Wait a moment and try again."))
        #expect(viewModel.isPosting == false)
    }

    @Test func eachPostFailureHasItsOwnMessage() async {
        let cases: [(Error, String)] = [
            (CommentError.signInRequired, String(localized: "Your session expired. Sign in again to comment.")),
            (CommentError.notFound, String(localized: "This clip is no longer available.")),
            (CommentError.invalidBody, String(localized: "Comments can be up to \(CommentRules.maxCharacters) characters.")),
            (CommentError.serverError(500), String(localized: "Couldn't post your comment. Try again.")),
            (StubError.uploadFailed, String(localized: "Couldn't post your comment. Try again.")),
        ]
        for (error, message) in cases {
            let (viewModel, repository) = await loadedSUT([])
            repository.postResult = .failure(error)
            viewModel.draft = "Hello"

            await viewModel.post()

            #expect(viewModel.errorMessage == message)
        }
    }

    @Test func aNewPostClearsTheEarlierErrorMessage() async {
        let (viewModel, repository) = await loadedSUT([])
        repository.postResult = .failure(CommentError.rateLimited)
        viewModel.draft = "Hello"
        await viewModel.post()
        #expect(viewModel.errorMessage != nil)

        repository.postResult = nil
        await viewModel.post()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.comments.count == 1)
    }

    @Test func clearErrorRemovesTheMessage() async {
        let (viewModel, repository) = await loadedSUT([])
        repository.postResult = .failure(CommentError.rateLimited)
        viewModel.draft = "Hello"
        await viewModel.post()

        viewModel.clearError()

        #expect(viewModel.errorMessage == nil)
    }

    @Test func aBlankDraftIsNeverSent() async {
        let (viewModel, repository) = await loadedSUT([])
        viewModel.draft = "  \n "

        #expect(viewModel.canPost == false)
        await viewModel.post()

        #expect(repository.posts.isEmpty)
    }

    @Test func aDraftOfInvisibleCharactersIsNeverSent() async {
        let (viewModel, repository) = await loadedSUT([])
        viewModel.draft = "\u{200B}\u{2800}\u{3164}"

        #expect(viewModel.canPost == false)
        await viewModel.post()

        #expect(repository.posts.isEmpty)
        #expect(viewModel.draft == "\u{200B}\u{2800}\u{3164}")
    }

    @Test func textTypedWhilePostingIsNotErased() async {
        let (viewModel, repository) = await loadedSUT([])
        viewModel.draft = "first"
        repository.beforePostReturns = { [viewModel] in
            // The viewer starts the next comment while the request is still in flight.
            await MainActor.run { viewModel.draft = "second" }
        }

        await viewModel.post()

        #expect(viewModel.comments.map(\.body) == ["first"])
        #expect(viewModel.draft == "second")
    }

    @Test func aSecondTapWhilePostingSendsNothing() async {
        let (viewModel, repository) = await loadedSUT([])
        viewModel.draft = "first"
        let sawPosting = Flag()
        let interleave = OneShot()
        repository.beforePostReturns = { [viewModel] in
            guard interleave.claim() else { return }
            sawPosting.value = await viewModel.isPosting
            await viewModel.post()
        }

        await viewModel.post()

        #expect(sawPosting.value)
        #expect(repository.posts.count == 1)
        #expect(viewModel.isPosting == false)
    }

    @Test func aDraftOverTheLimitIsNeverSent() async {
        let (viewModel, repository) = await loadedSUT([])
        viewModel.draft = String(repeating: "a", count: CommentRules.maxCharacters + 1)

        #expect(viewModel.isOverLimit)
        #expect(viewModel.remainingCharacters == -1)
        #expect(viewModel.canPost == false)
        await viewModel.post()

        #expect(repository.posts.isEmpty)
        #expect(viewModel.draft.count == CommentRules.maxCharacters + 1)
    }

    @Test func aDraftAtTheLimitCanBeSent() async {
        let (viewModel, _) = await loadedSUT([])
        viewModel.draft = String(repeating: "a", count: CommentRules.maxCharacters)

        #expect(viewModel.remainingCharacters == 0)
        #expect(viewModel.isOverLimit == false)
        #expect(viewModel.canPost)
    }

    @Test func remainingCharactersIgnoresSurroundingWhitespace() async {
        let (viewModel, _) = await loadedSUT([])
        viewModel.draft = "  abc  \n"

        #expect(viewModel.remainingCharacters == CommentRules.maxCharacters - 3)
    }

    @Test func aDraftOfOnlyWhitespaceIsNotWorthKeeping() {
        let (viewModel, _) = makeSUT()
        #expect(viewModel.hasDraft == false)

        viewModel.draft = "  \n "
        #expect(viewModel.hasDraft == false)

        viewModel.draft = " hi "
        #expect(viewModel.hasDraft)
    }

    @Test func nothingIsPostedBeforeTheListHasLoaded() async {
        let (viewModel, repository) = makeSUT()
        viewModel.draft = "Hello"

        #expect(viewModel.canPost == false)
        await viewModel.post()

        #expect(repository.posts.isEmpty)
    }

    @Test func theSendButtonIsOffWhileAPostIsOnItsWay() async {
        let (viewModel, repository) = await loadedSUT([])
        viewModel.draft = "Hello"
        #expect(viewModel.canPost)
        let canPostWhileOut = Flag()
        repository.beforePostReturns = { [viewModel] in
            canPostWhileOut.value = await viewModel.canPost
        }

        await viewModel.post()

        #expect(repository.posts.count == 1)
        #expect(canPostWhileOut.value == false)
    }

    @Test func aRefreshThatAlreadyListsTheStoredCommentDoesNotListItTwiceWhenThePostAnswers() async {
        let old = comment("old")
        let posted = comment("Hello", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [old], nextCursor: nil)),
            .success(CommentPage(items: [posted, old], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        repository.postResult = .success(posted)
        viewModel.draft = "Hello"
        repository.beforePostReturns = { [viewModel] in
            // A pull to refresh finishes before the answer to the post does, and already lists the stored comment.
            await viewModel.reload()
        }

        await viewModel.post()

        #expect(viewModel.comments.map(\.id) == [posted.id, old.id])
    }

    @Test func aSlowPostAnswerDoesNotBringBackACommentTheViewerDeleted() async {
        let old = comment("old")
        let posted = comment("Hello", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [old], nextCursor: nil)),
            .success(CommentPage(items: [posted, old], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        repository.postResult = .success(posted)
        viewModel.draft = "Hello"
        repository.beforePostReturns = { [viewModel] in
            // A refresh lists the stored comment and the viewer deletes it, all before the post's own answer arrives.
            await viewModel.reload()
            await viewModel.delete(posted)
        }

        await viewModel.post()

        #expect(viewModel.comments.map(\.body) == ["old"])
        #expect(viewModel.draft.isEmpty)
    }

    @Test func aSlowPostAnswerDoesNotBringBackACommentDeletedBeforeALaterRefresh() async {
        let old = comment("old")
        let posted = comment("Hello", canDelete: true)
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(CommentPage(items: [old], nextCursor: nil)),
            .success(CommentPage(items: [posted, old], nextCursor: nil)),
            .success(CommentPage(items: [old], nextCursor: nil)),
        ])
        await viewModel.loadIfNeeded()
        repository.postResult = .success(posted)
        viewModel.draft = "Hello"
        repository.beforePostReturns = { [viewModel] in
            // The viewer deletes the stored comment and refreshes once more, all before the post's own answer arrives.
            await viewModel.reload()
            await viewModel.delete(posted)
            await viewModel.reload()
        }

        await viewModel.post()

        #expect(repository.fetches.count == 3)
        #expect(viewModel.comments.map(\.body) == ["old"])
    }

    // MARK: - Deleting

    @Test func deletingRemovesTheComment() async {
        let mine = comment("mine", canDelete: true)
        let (viewModel, repository) = await loadedSUT([mine, comment("other")])

        await viewModel.delete(mine)

        #expect(repository.deletes.count == 1)
        #expect(repository.deletes.first?.videoID == Self.videoID)
        #expect(repository.deletes.first?.commentID == mine.id)
        #expect(viewModel.comments.map(\.body) == ["other"])
        #expect(viewModel.isDeleting(mine) == false)
    }

    @Test func aCommentAlreadyRemovedByTheOwnerJustDisappears() async {
        let mine = comment("mine", canDelete: true)
        let (viewModel, repository) = await loadedSUT([mine])
        repository.deleteResult = .failure(CommentError.notFound)

        await viewModel.delete(mine)

        #expect(viewModel.comments.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func aFailedDeleteKeepsTheCommentAndExplainsWhy() async {
        let mine = comment("mine", canDelete: true)
        let (viewModel, repository) = await loadedSUT([mine])
        repository.deleteResult = .failure(StubError.uploadFailed)

        await viewModel.delete(mine)

        #expect(viewModel.comments == [mine])
        #expect(viewModel.errorMessage == String(localized: "Couldn't delete the comment. Try again."))
        #expect(viewModel.isDeleting(mine) == false)
    }

    @Test func anExpiredSessionIsSaidOutLoudWhenDeleting() async {
        let mine = comment("mine", canDelete: true)
        let (viewModel, repository) = await loadedSUT([mine])
        repository.deleteResult = .failure(CommentError.signInRequired)

        await viewModel.delete(mine)

        #expect(viewModel.errorMessage == String(localized: "Your session expired. Sign in again to comment."))
        #expect(viewModel.comments == [mine])
    }

    @Test func aDeleteClearsTheEarlierErrorMessage() async {
        let mine = comment("mine", canDelete: true)
        let (viewModel, repository) = await loadedSUT([mine])
        repository.postResult = .failure(CommentError.rateLimited)
        viewModel.draft = "Hello"
        await viewModel.post()
        #expect(viewModel.errorMessage != nil)

        await viewModel.delete(mine)

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.comments.isEmpty)
    }

    @Test func commentsTheViewerCannotDeleteAreNeverSent() async {
        let theirs = comment("theirs", canDelete: false)
        let (viewModel, repository) = await loadedSUT([theirs])

        await viewModel.delete(theirs)

        #expect(repository.deletes.isEmpty)
        #expect(viewModel.comments == [theirs])
    }

    @Test func aSecondDeleteWhileOneIsInFlightSendsNothing() async {
        let mine = comment("mine", canDelete: true)
        let (viewModel, repository) = await loadedSUT([mine])
        let sawDeleting = Flag()
        let interleave = OneShot()
        repository.beforeDeleteReturns = { [viewModel] in
            guard interleave.claim() else { return }
            sawDeleting.value = await viewModel.isDeleting(mine)
            await viewModel.delete(mine)
        }

        await viewModel.delete(mine)

        #expect(sawDeleting.value)
        #expect(repository.deletes.count == 1)
        #expect(viewModel.comments.isEmpty)
    }
}

@MainActor
struct UITestCommentRepositoryTests {
    private let videoID = UUID()

    @Test func everyClipStartsWithTwoCommentsOfWhichOneIsDeletable() async throws {
        let repository = UITestCommentRepository()

        let page = try await repository.fetchComments(videoID: videoID, cursor: nil, limit: 30)

        #expect(page.items.count == 2)
        #expect(page.items.filter(\.canDelete).count == 1)
        #expect(page.nextCursor == nil)
    }

    @Test func postedCommentsGoFirstAndCanBeDeleted() async throws {
        let repository = UITestCommentRepository()

        let posted = try await repository.postComment(videoID: videoID, body: "Hi", language: nil)
        var page = try await repository.fetchComments(videoID: videoID, cursor: nil, limit: 30)
        #expect(page.items.first == posted)
        #expect(page.items.count == 3)

        try await repository.deleteComment(videoID: videoID, commentID: posted.id)
        page = try await repository.fetchComments(videoID: videoID, cursor: nil, limit: 30)
        #expect(page.items.count == 2)
    }

    @Test func commentsBelongToTheirOwnClip() async throws {
        let repository = UITestCommentRepository()
        _ = try await repository.postComment(videoID: videoID, body: "Hi", language: nil)

        let other = try await repository.fetchComments(videoID: UUID(), cursor: nil, limit: 30)

        #expect(other.items.count == 2)
    }
}

/// Lets only the first caller through, so a test can interleave exactly one extra action.
private final class OneShot: @unchecked Sendable {
    private var used = false

    func claim() -> Bool {
        defer { used = true }
        return !used
    }
}

/// Carries a value out of a test double's hook, which runs outside the main actor.
private final class Flag: @unchecked Sendable {
    var value = false
}

/// Numbers the calls to a hook, so a test can give the first and the second request different behaviour.
private final class Counter: @unchecked Sendable {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
