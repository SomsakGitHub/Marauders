//
//  FollowListViewModel.swift
//  Marauders
//

import Foundation
import Observation

/// One list of a profile: the accounts that follow it or the accounts it follows, loaded a page at a time.
@MainActor
@Observable
final class FollowListViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let handle: String
    let kind: FollowListKind
    private(set) var state: LoadState = .idle
    /// Newest follow first, one row per account.
    private(set) var entries: [FollowListEntry] = []
    /// Whether the Worker holds rows after the last one listed.
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// The last page request failed. Scrolling does not retry it: `retryLoadMore()` does.
    private(set) var loadMoreFailed = false
    /// A request came back 401: the session has ended, and the view asks the viewer to sign in.
    private(set) var needsSignIn = false

    /// The Worker's cursor for the page after the last one accepted. Opaque here.
    @ObservationIgnored private var cursor: String?
    /// Bumped by every reload and every reset, so a slow answer from before it cannot overwrite newer rows.
    @ObservationIgnored private var loadGeneration = 0
    /// True while the newest reload is in flight. The list stays on screen, but it must not grow under the refresh.
    @ObservationIgnored private var isReloading = false
    private let loadList: LoadFollowListUseCase

    init(handle: String, kind: FollowListKind, loadList: LoadFollowListUseCase) {
        self.handle = handle
        self.kind = kind
        self.loadList = loadList
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    /// Loads the first page again. A list that is already showing stays on screen while it refreshes, and stays as it
    /// is when the refresh fails.
    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isReloading = true
        defer {
            if generation == loadGeneration { isReloading = false }
        }
        isLoadingMore = false
        loadMoreFailed = false
        needsSignIn = false
        if state != .loaded { state = .loading }
        do {
            let page = try await loadList.execute(handle: handle, kind: kind)
            guard generation == loadGeneration else { return }
            entries = Self.newEntries(in: page.entries, besides: [])
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
            state = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            // A load that was cancelled (SwiftUI cancels the task that started it when the viewer leaves the tab) has not
            // failed. A list with nothing yet goes back to waiting, so showing it again loads it.
            if Task.isCancelled {
                if state == .loading { state = .idle }
                return
            }
            AppLog.warning("follow-list", "load failed: \(error.localizedDescription)")
            noteSessionEnded(by: error)
            if state != .loaded { state = .failed(Self.loadMessage(for: error)) }
        }
    }

    /// Called as `entry` appears; fetches the next page when it is near the end of the list.
    func loadMoreIfNeeded(currentItem entry: FollowListEntry) async {
        guard state == .loaded, hasMore, !isLoadingMore, !loadMoreFailed, !isReloading,
            let index = entries.firstIndex(where: { $0.id == entry.id }),
            index >= entries.count - FollowListRules.prefetchDistance
        else { return }
        await loadMore()
    }

    /// Asks again for the page that failed.
    func retryLoadMore() async {
        guard state == .loaded, hasMore, !isLoadingMore, !isReloading else { return }
        await loadMore()
    }

    /// Forgets everything and drops any answer still on its way: after a sign-in or sign-out the list belongs to a
    /// different viewer.
    func resetForSessionChange() {
        loadGeneration += 1
        isReloading = false
        state = .idle
        entries = []
        cursor = nil
        hasMore = false
        isLoadingMore = false
        loadMoreFailed = false
        needsSignIn = false
    }

    private func loadMore() async {
        guard let sent = cursor else { return }
        let generation = loadGeneration
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let page = try await loadList.execute(handle: handle, kind: kind, cursor: sent)
            guard generation == loadGeneration else { return }
            isLoadingMore = false
            entries.append(contentsOf: Self.newEntries(in: page.entries, besides: entries))
            cursor = page.nextCursor
            // A Worker that answers with the cursor it was given would be asked the same question for as long as the
            // last rows stay on screen.
            hasMore = page.nextCursor != nil && page.nextCursor != sent
        } catch {
            guard generation == loadGeneration else { return }
            isLoadingMore = false
            // A cancelled request has not failed: the next row that appears asks again.
            if Task.isCancelled { return }
            AppLog.warning("follow-list", "load more failed: \(error.localizedDescription)")
            loadMoreFailed = true
            noteSessionEnded(by: error)
        }
    }

    private func noteSessionEnded(by error: Error) {
        if let error = error as? FollowListError, error == .signInRequired {
            needsSignIn = true
        }
    }

    /// The rows of `page` that `known` does not list yet, once each: an account counts once whatever its spelling, and
    /// a follow made while the viewer scrolled can make the Worker repeat a row.
    private static func newEntries(in page: [FollowListEntry], besides known: [FollowListEntry]) -> [FollowListEntry] {
        var seen = Set(known.map(\.id))
        return page.filter { seen.insert($0.id).inserted }
    }

    private static func loadMessage(for error: Error) -> String {
        switch error as? FollowListError {
        case .notFound:
            return "This profile is no longer available"
        case .rateLimited:
            return "Too many requests, try again in a moment"
        case .signInRequired:
            return "Sign in required"
        default:
            return "Couldn't load this list"
        }
    }
}
