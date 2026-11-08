//
//  FollowListViewModelTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct FollowListViewModelTests {
    private static let handle = "@alice"

    private func entry(_ handle: String, followedByViewer: Bool = false) -> FollowListEntry {
        FollowListEntry(handle: handle, avatarURL: nil, followedByViewer: followedByViewer, isViewer: false)
    }

    private func entries(count: Int, prefix: String = "user") -> [FollowListEntry] {
        (0 ..< count).map { entry("@\(prefix)\($0)") }
    }

    private func page(_ entries: [FollowListEntry], nextCursor: String? = nil) -> FollowListPage {
        FollowListPage(entries: entries, nextCursor: nextCursor)
    }

    private func makeSUT(
        kind: FollowListKind = .followers,
        fetchResults: [Result<FollowListPage, Error>] = [.success(FollowListPage(entries: [], nextCursor: nil))]
    ) -> (FollowListViewModel, StubFollowListRepository) {
        let repository = StubFollowListRepository(fetchResults: fetchResults)
        let viewModel = FollowListViewModel(
            handle: Self.handle,
            kind: kind,
            loadList: LoadFollowListUseCase(repository: repository)
        )
        return (viewModel, repository)
    }

    /// A model that has loaded `first`, with the Worker's cursor "c1" when `hasMore`, and whose later answers are `then`.
    private func loadedSUT(
        _ first: [FollowListEntry],
        hasMore: Bool = true,
        then: [Result<FollowListPage, Error>] = []
    ) async -> (FollowListViewModel, StubFollowListRepository) {
        let firstPage: Result<FollowListPage, Error> = .success(page(first, nextCursor: hasMore ? "c1" : nil))
        let (viewModel, repository) = makeSUT(fetchResults: [firstPage] + then)
        await viewModel.loadIfNeeded()
        return (viewModel, repository)
    }

    // MARK: - Loading

    @Test func loadShowsTheFirstPage() async {
        let rows = [entry("@bob"), entry("@carol", followedByViewer: true)]
        let (viewModel, repository) = makeSUT(kind: .following, fetchResults: [.success(page(rows))])
        #expect(viewModel.state == .idle)

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries == rows)
        #expect(!viewModel.hasMore)
        #expect(!viewModel.needsSignIn)
        #expect(repository.fetches.count == 1)
        #expect(repository.fetches.first?.handle == "@alice")
        #expect(repository.fetches.first?.kind == .following)
        #expect(repository.fetches.first?.cursor == nil)
        #expect(repository.fetches.first?.limit == FollowListRules.pageSize)
    }

    @Test func anAccountWithoutFollowersLoadsAsEmpty() async {
        let (viewModel, _) = makeSUT()

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.isEmpty)
        #expect(!viewModel.hasMore)
    }

    @Test func loadIfNeededOnlyLoadsOnce() async {
        let (viewModel, repository) = makeSUT()

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(repository.fetches.count == 1)
    }

    @Test func reloadReplacesTheListWithTheFirstPage() async {
        let (viewModel, repository) = await loadedSUT(entries(count: 3), then: [.success(page([entry("@new")]))])

        await viewModel.reload()

        #expect(repository.fetches.count == 2)
        #expect(repository.fetches.last?.cursor == nil)
        #expect(viewModel.entries == [entry("@new")])
        #expect(!viewModel.hasMore)
        #expect(viewModel.state == .loaded)
    }

    // MARK: - Failures

    @Test(arguments: [
        (FollowListError.notFound, "This profile is no longer available"),
        (FollowListError.rateLimited, "Too many requests, try again in a moment"),
        (FollowListError.serverError(500), "Couldn't load this list"),
        (FollowListError.invalidResponse, "Couldn't load this list"),
        (URLError(.notConnectedToInternet), "Couldn't load this list"),
    ] as [(any Error, String)])
    func aFailedFirstLoadShowsTheRightMessage(error: any Error, message: String) async {
        let (viewModel, _) = makeSUT(fetchResults: [.failure(error)])

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .failed(message))
        #expect(!viewModel.needsSignIn)
        #expect(viewModel.entries.isEmpty)
    }

    @Test func aRejectedSessionAsksToSignIn() async {
        let (viewModel, _) = makeSUT(fetchResults: [.failure(FollowListError.signInRequired)])

        await viewModel.loadIfNeeded()

        #expect(viewModel.needsSignIn)
        #expect(viewModel.state == .failed("Sign in required"))
    }

    @Test func aFailedLoadCanBeRetried() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .failure(FollowListError.signInRequired),
            .success(page([entry("@bob")])),
        ])
        await viewModel.loadIfNeeded()
        #expect(viewModel.needsSignIn)

        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(!viewModel.needsSignIn)
        #expect(viewModel.entries == [entry("@bob")])
        #expect(repository.fetches.count == 2)
    }

    @Test func aFailedRefreshKeepsTheListOnScreen() async {
        let rows = entries(count: 3)
        let (viewModel, _) = await loadedSUT(rows, then: [.failure(FollowListError.serverError(500))])

        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries == rows)
        #expect(viewModel.hasMore)
        #expect(!viewModel.needsSignIn)
    }

    @Test func aRejectedSessionDuringARefreshAsksToSignInAndKeepsTheRows() async {
        let rows = entries(count: 3)
        let (viewModel, _) = await loadedSUT(rows, then: [.failure(FollowListError.signInRequired)])

        await viewModel.reload()

        #expect(viewModel.needsSignIn)
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries == rows)
    }

    // MARK: - Paging

    @Test func aRowNearTheEndLoadsTheNextPageWithTheWorkersCursor() async {
        let first = entries(count: 30)
        let (viewModel, repository) = await loadedSUT(first, then: [.success(page(entries(count: 30, prefix: "next")))])

        await viewModel.loadMoreIfNeeded(currentItem: first[25])

        #expect(repository.fetches.count == 2)
        #expect(repository.fetches.last?.cursor == "c1")
        #expect(repository.fetches.last?.limit == FollowListRules.pageSize)
        #expect(viewModel.entries.count == 60)
        #expect(!viewModel.hasMore)
        #expect(!viewModel.isLoadingMore)
    }

    @Test func aRowFarFromTheEndLoadsNothing() async {
        let first = entries(count: 30)
        let (viewModel, repository) = await loadedSUT(first)

        await viewModel.loadMoreIfNeeded(currentItem: first[24])

        #expect(repository.fetches.count == 1)
        #expect(viewModel.entries.count == 30)
    }

    @Test func nothingLoadsMoreBeforeTheFirstPageIsIn() async {
        let (viewModel, repository) = makeSUT()

        await viewModel.loadMoreIfNeeded(currentItem: entry("@bob"))

        #expect(repository.fetches.isEmpty)
    }

    @Test func theLastPageEndsTheList() async {
        let first = entries(count: 30)
        let (viewModel, repository) = await loadedSUT(first, hasMore: false)
        #expect(!viewModel.hasMore)

        await viewModel.loadMoreIfNeeded(currentItem: first[29])

        #expect(repository.fetches.count == 1)
    }

    @Test func aPageThatRepeatsRowsAddsOnlyTheNewOnes() async {
        let first = entries(count: 29) + [entry("@bob")]
        let (viewModel, _) = await loadedSUT(first, then: [.success(page([entry("@Bob"), entry("@new")]))])

        await viewModel.loadMoreIfNeeded(currentItem: first[29])

        #expect(viewModel.entries.count == 31)
        #expect(viewModel.entries.last?.handle == "@new")
        #expect(viewModel.entries.filter { $0.id == "@bob" }.count == 1)
    }

    @Test func aWorkerThatRepeatsTheCursorEndsTheList() async {
        let first = entries(count: 30)
        let (viewModel, _) = await loadedSUT(first, then: [.success(page([entry("@new")], nextCursor: "c1"))])

        await viewModel.loadMoreIfNeeded(currentItem: first[29])

        #expect(viewModel.entries.count == 31)
        #expect(!viewModel.hasMore)
    }

    @Test func aFailedPageWaitsForTryAgain() async {
        let first = entries(count: 30)
        let (viewModel, repository) = await loadedSUT(first, then: [
            .failure(FollowListError.serverError(500)),
            .success(page([entry("@new")])),
        ])

        await viewModel.loadMoreIfNeeded(currentItem: first[29])

        #expect(viewModel.loadMoreFailed)
        #expect(!viewModel.isLoadingMore)
        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries.count == 30)
        #expect(repository.fetches.count == 2)

        // Scrolling to the same row again does not ask again: only Try Again does.
        await viewModel.loadMoreIfNeeded(currentItem: first[29])
        #expect(repository.fetches.count == 2)

        await viewModel.retryLoadMore()

        #expect(!viewModel.loadMoreFailed)
        #expect(repository.fetches.count == 3)
        #expect(repository.fetches.last?.cursor == "c1")
        #expect(viewModel.entries.count == 31)
    }

    @Test func aRejectedSessionOnALaterPageAsksToSignIn() async {
        let first = entries(count: 30)
        let (viewModel, _) = await loadedSUT(first, then: [.failure(FollowListError.signInRequired)])

        await viewModel.loadMoreIfNeeded(currentItem: first[29])

        #expect(viewModel.loadMoreFailed)
        #expect(viewModel.needsSignIn)
        #expect(viewModel.entries.count == 30)
    }

    @Test func aRowAppearingDuringARefreshLoadsNoPage() async {
        let first = entries(count: 30)
        let (viewModel, repository) = await loadedSUT(first, then: [.success(page(entries(count: 30, prefix: "fresh"), nextCursor: "c2"))])
        repository.beforeFetchReturns = { [viewModel] count in
            guard count == 2 else { return }
            // The refresh is out, and a row near the end of the old list appears.
            await viewModel.loadMoreIfNeeded(currentItem: first[29])
        }

        await viewModel.reload()

        #expect(repository.fetches.count == 2)
        #expect(viewModel.entries.count == 30)
        #expect(viewModel.entries.first?.handle == "@fresh0")
    }

    // MARK: - Answers that arrive late

    @Test func anOlderAnswerIsDroppedAfterARefresh() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .success(page([entry("@old")])),
            .success(page([entry("@fresh")])),
        ])
        repository.beforeFetchReturns = { [viewModel] count in
            guard count == 1 else { return }
            // The first request is still out when a refresh starts and finishes.
            await viewModel.reload()
        }

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries == [entry("@fresh")])
        #expect(repository.fetches.count == 2)
    }

    @Test func aRefreshDuringAPageRequestDropsThatPage() async {
        let first = entries(count: 30)
        let (viewModel, repository) = await loadedSUT(first, then: [
            .success(page([entry("@stalePage")], nextCursor: "c2")),
            .success(page([entry("@fresh")])),
        ])
        repository.beforeFetchReturns = { [viewModel] count in
            guard count == 2 else { return }
            // The next page is out when the viewer pulls to refresh.
            await viewModel.reload()
        }

        await viewModel.loadMoreIfNeeded(currentItem: first[29])

        #expect(viewModel.entries == [entry("@fresh")])
        #expect(!viewModel.hasMore)
        #expect(!viewModel.isLoadingMore)
        #expect(viewModel.state == .loaded)
    }

    @Test func aSessionChangeDropsAnAnswerInFlight() async {
        let (viewModel, repository) = makeSUT(fetchResults: [.success(page([entry("@old")]))])
        repository.beforeFetchReturns = { [viewModel] _ in
            await MainActor.run { viewModel.resetForSessionChange() }
        }

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .idle)
        #expect(viewModel.entries.isEmpty)
        #expect(!viewModel.hasMore)
    }

    /// SwiftUI cancels the task that started a load when the viewer leaves the tab, and the HTTP client reports that as a
    /// transport error. A load that was only cancelled has not failed: showing the tab again asks again.
    @Test func aLoadCancelledWhileItsFirstPageIsOutGoesBackToWaiting() async {
        let (viewModel, repository) = makeSUT(fetchResults: [
            .failure(HTTPClientError.transport("cancelled")),
            .success(page([entry("@bob")])),
        ])
        let load = LoadTask()
        repository.beforeFetchReturns = { count in
            if count == 1 { load.task?.cancel() }
        }
        load.task = Task { await viewModel.loadIfNeeded() }
        await load.task?.value

        #expect(viewModel.state == .idle)
        #expect(viewModel.entries.isEmpty)

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.entries == [entry("@bob")])
        #expect(repository.fetches.count == 2)
    }

    @Test func aPageRequestCancelledWhileItIsOutIsNotAFailure() async {
        let first = entries(count: 30)
        let (viewModel, repository) = await loadedSUT(first, then: [
            .failure(HTTPClientError.transport("cancelled")),
            .success(page([entry("@more")])),
        ])
        let load = LoadTask()
        repository.beforeFetchReturns = { count in
            if count == 2 { load.task?.cancel() }
        }
        load.task = Task { await viewModel.loadMoreIfNeeded(currentItem: first[29]) }
        await load.task?.value

        #expect(!viewModel.loadMoreFailed)
        #expect(!viewModel.isLoadingMore)
        #expect(viewModel.hasMore)

        await viewModel.loadMoreIfNeeded(currentItem: first[29])

        #expect(viewModel.entries.last == entry("@more"))
        #expect(repository.fetches.count == 3)
    }

    @Test func resetForSessionChangeEmptiesTheList() async {
        let (viewModel, repository) = await loadedSUT(entries(count: 3), then: [.success(page([entry("@again")]))])

        viewModel.resetForSessionChange()

        #expect(viewModel.state == .idle)
        #expect(viewModel.entries.isEmpty)
        #expect(!viewModel.hasMore)
        #expect(!viewModel.needsSignIn)
        #expect(!viewModel.loadMoreFailed)
        #expect(!viewModel.isLoadingMore)

        await viewModel.loadIfNeeded()

        #expect(repository.fetches.count == 2)
        #expect(repository.fetches.last?.cursor == nil)
        #expect(viewModel.entries == [entry("@again")])
    }

    @Test func resetForSessionChangeClearsTheSignInPrompt() async {
        let (viewModel, _) = makeSUT(fetchResults: [.failure(FollowListError.signInRequired)])
        await viewModel.loadIfNeeded()
        #expect(viewModel.needsSignIn)

        viewModel.resetForSessionChange()

        #expect(!viewModel.needsSignIn)
        #expect(viewModel.state == .idle)
    }
}

/// Holds the task a test starts, so the stub's "in flight" hook can cancel it the way SwiftUI cancels a view's task.
private final class LoadTask: @unchecked Sendable {
    var task: Task<Void, Never>?
}
