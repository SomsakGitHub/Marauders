//
//  UserFollowsViewModelTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct UserFollowsViewModelTests {
    private func change(_ following: Bool, followers: Int, viewerFollows: Int = 1) -> UserFollowChange {
        UserFollowChange(following: following, followerCount: followers, viewerFollowingCount: viewerFollows)
    }

    private func makeSUT(
        _ results: [Result<UserFollowChange, Error>] = [
            .success(UserFollowChange(following: true, followerCount: 4, viewerFollowingCount: 1))
        ]
    ) -> (UserFollowsViewModel, StubUserFollowRepository) {
        let repository = StubUserFollowRepository(results: results)
        return (UserFollowsViewModel(setFollow: SetUserFollowUseCase(repository: repository)), repository)
    }

    /// Waits, for up to two seconds, for work the view model starts as a task of its own.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finish(_ viewModel: UserFollowsViewModel) async {
        await waitUntil { !viewModel.isBusy }
    }

    // MARK: - What the screens loaded

    @Test func anAccountNobodyTouchedShowsWhatTheScreenLoaded() {
        let (viewModel, repository) = makeSUT()

        #expect(viewModel.isFollowing("@alice", fallback: true))
        #expect(!viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: 12) == 12)
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == nil)
        #expect(repository.calls.isEmpty)
    }

    // MARK: - Tapping

    @Test func aFollowShowsAtOnceAndTheWorkersCountReplacesTheGuess() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 9))])
        let stamp = viewModel.stamp()
        viewModel.record("@alice", following: false, followerCount: 3, loadedAt: stamp)

        viewModel.toggle("@alice", fallback: false)
        // Nothing has been answered yet: this is the viewer's own guess.
        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: 3) == 4)
        #expect(viewModel.isBusy)

        await finish(viewModel)

        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: 3) == 9)
        #expect(repository.calls.map(\.following) == [true])
        #expect(repository.calls.map(\.handle) == ["@alice"])
    }

    @Test func tappingAFollowedAccountStopsFollowingIt() async {
        let (viewModel, repository) = makeSUT([.success(change(false, followers: 2))])

        viewModel.toggle("@alice", fallback: true)
        #expect(!viewModel.isFollowing("@alice", fallback: true))

        await finish(viewModel)

        #expect(!viewModel.isFollowing("@alice", fallback: true))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 2)
        #expect(repository.calls.map(\.following) == [false])
    }

    /// The feed counts nobody's followers: until the Worker answers, the profile's own number is shown.
    @Test func aFollowFromTheFeedGuessesNoCount() async {
        let (viewModel, _) = makeSUT([.success(change(true, followers: 7))])

        viewModel.toggle("@alice", fallback: false)
        #expect(viewModel.followerCount(of: "@alice", fallback: 5) == 5)

        await finish(viewModel)
        #expect(viewModel.followerCount(of: "@alice", fallback: 5) == 7)
    }

    @Test func theSameAccountIsOneEntryWhateverTheSpellingOfItsHandle() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 1))])

        viewModel.toggle("Alice", fallback: false)
        await finish(viewModel)

        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.isFollowing("@ALICE", fallback: false))
        #expect(repository.calls.map(\.handle) == ["@alice"], "the Worker is sent the handle as it stores it")
    }

    @Test func accountsAreFollowedIndependently() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 1))])

        viewModel.toggle("@alice", fallback: false)
        viewModel.toggle("@bob", fallback: false)
        await finish(viewModel)

        #expect(Set(repository.calls.map(\.handle)) == ["@alice", "@bob"])
        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.isFollowing("@bob", fallback: false))
        #expect(!viewModel.isFollowing("@carol", fallback: false))
    }

    @Test func theGuessNeverShowsANegativeCount() {
        let (viewModel, _) = makeSUT()
        viewModel.record("@alice", following: true, followerCount: 0, loadedAt: viewModel.stamp())

        viewModel.toggle("@alice", fallback: true)

        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 0)
    }

    @Test func everyAnswerTellsTheViewersOwnProfileHowManyTheyFollow() async {
        let (viewModel, _) = makeSUT([
            .success(change(true, followers: 1, viewerFollows: 3)),
            .success(change(false, followers: 0, viewerFollows: 2)),
        ])
        var reported: [Int] = []
        viewModel.onViewerFollowingCountChange = { reported.append($0) }

        viewModel.toggle("@alice", fallback: false)
        await finish(viewModel)
        viewModel.toggle("@alice", fallback: false)
        await finish(viewModel)

        #expect(reported == [3, 2])
    }

    // MARK: - The feed's "+"

    @Test func thePlusFollowsAnAccountTheViewerDoesNotFollowYet() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 1))])

        viewModel.follow("@alice", fallback: false)
        #expect(viewModel.isFollowing("@alice", fallback: false))

        await finish(viewModel)
        #expect(repository.calls.map(\.following) == [true])
    }

    @Test func thePlusNeverStopsAFollow() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 1))])

        viewModel.follow("@alice", fallback: true)
        #expect(!viewModel.isBusy)

        viewModel.follow("@bob", fallback: false)
        await finish(viewModel)
        viewModel.follow("@bob", fallback: false)

        #expect(repository.calls.map(\.handle) == ["@bob"])
        #expect(viewModel.isFollowing("@bob", fallback: false))
    }

    // MARK: - Failures

    @Test(arguments: [
        UserFollowError.serverError(500), .rateLimited, .notFound, .signInRequired, .invalidResponse, .cannotFollowSelf,
    ])
    func aFailureGoesBackToWhatTheScreenLoaded(error: UserFollowError) async {
        let (viewModel, _) = makeSUT([.failure(error)])
        viewModel.record("@alice", following: false, followerCount: 3, loadedAt: viewModel.stamp())

        viewModel.toggle("@alice", fallback: false)
        await finish(viewModel)

        #expect(!viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 3)
        #expect(!viewModel.isBusy)
    }

    @Test func aFailedFollowFromTheFeedGoesBackToWhatTheFeedSaid() async {
        let (viewModel, _) = makeSUT([.failure(UserFollowError.serverError(503))])

        viewModel.follow("@alice", fallback: false)
        await finish(viewModel)

        #expect(!viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: 8) == 8)
    }

    @Test func aFailureGoesBackToTheWorkersLastAnswer() async {
        let (viewModel, _) = makeSUT([
            .success(change(true, followers: 9)),
            .failure(UserFollowError.serverError(503)),
        ])

        viewModel.toggle("@alice", fallback: false)
        await finish(viewModel)
        viewModel.toggle("@alice", fallback: false)
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 8)
        await finish(viewModel)

        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 9)
    }

    // MARK: - Taps while a request is out

    @Test func aSecondTapWhileTheFirstIsOutIsSentAfterItAndLeavesOneRequestOutAtATime() async {
        let (viewModel, repository) = makeSUT([
            .success(change(true, followers: 4)),
            .success(change(false, followers: 3)),
        ])
        let firstRequest = FollowGate(), secondRequest = FollowGate()
        repository.beforeReturn = { call in await (call == 1 ? firstRequest : secondRequest).wait() }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle("@alice", fallback: false)
        #expect(!viewModel.isFollowing("@alice", fallback: false))
        #expect(repository.calls.count == 1, "the second tap must wait for the first request")

        await firstRequest.open()
        await waitUntil { repository.calls.count == 2 }
        // The Worker said 4 with the follow; without it that is 3.
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 3)
        #expect(!viewModel.isFollowing("@alice", fallback: false))
        await secondRequest.open()
        await finish(viewModel)

        #expect(repository.calls.map(\.following) == [true, false])
        #expect(repository.peakConcurrency == 1)
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 3)
    }

    /// Two follows the Worker ran side by side would each count the viewer's follows without the other's row, so the
    /// second account waits for the first one's answer.
    @Test func followsOfDifferentAccountsGoOutOneAtATime() async {
        let (viewModel, repository) = makeSUT([
            .success(change(true, followers: 1, viewerFollows: 1)),
            .success(change(true, followers: 5, viewerFollows: 2)),
        ])
        let firstRequest = FollowGate(), secondRequest = FollowGate()
        repository.beforeReturn = { call in await (call == 1 ? firstRequest : secondRequest).wait() }
        var reported: [Int] = []
        viewModel.onViewerFollowingCountChange = { reported.append($0) }

        viewModel.follow("@alice", fallback: false)
        viewModel.follow("@bob", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        #expect(viewModel.isFollowing("@bob", fallback: false), "the second follow shows at once even while it waits")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(repository.calls.count == 1, "@bob must wait for @alice's answer")

        await firstRequest.open()
        await waitUntil { repository.calls.count == 2 }
        await secondRequest.open()
        await finish(viewModel)

        #expect(repository.calls.map(\.handle) == ["@alice", "@bob"])
        #expect(repository.peakConcurrency == 1)
        #expect(reported == [1, 2])
        #expect(viewModel.followerCount(of: "@bob", fallback: nil) == 5)
    }

    /// A tap on an account that is still waiting its turn changes what is sent, not how many requests go.
    @Test func aWaitingAccountTappedAgainSendsOnlyItsLastChoice() async {
        let (viewModel, repository) = makeSUT([
            .success(change(true, followers: 1)),
            .success(change(true, followers: 3)),
        ])
        let firstRequest = FollowGate()
        repository.beforeReturn = { call in if call == 1 { await firstRequest.wait() } }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle("@bob", fallback: false)
        viewModel.toggle("@bob", fallback: false)
        viewModel.toggle("@bob", fallback: false)

        await firstRequest.open()
        await finish(viewModel)

        #expect(repository.calls.map(\.handle) == ["@alice", "@bob"])
        #expect(repository.calls.map(\.following) == [true, true])
    }

    @Test func anAccountWhoseTapsCancelOutWhileWaitingSendsNothing() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 1))])
        let firstRequest = FollowGate()
        repository.beforeReturn = { _ in await firstRequest.wait() }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle("@bob", fallback: false)
        viewModel.toggle("@bob", fallback: false)

        await firstRequest.open()
        await finish(viewModel)

        // @bob ended where the screen said it was, so asking the Worker would change nothing.
        #expect(!viewModel.isFollowing("@bob", fallback: false))
        #expect(repository.calls.map(\.handle) == ["@alice"])
    }

    /// Follow, unfollow, follow again before the first answer: the Worker already holds what the viewer ended on.
    @Test func tapsThatEndWhereTheRequestWentSendNothingMore() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 4))])
        let firstRequest = FollowGate()
        repository.beforeReturn = { _ in await firstRequest.wait() }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle("@alice", fallback: false)
        viewModel.toggle("@alice", fallback: false)

        await firstRequest.open()
        await finish(viewModel)

        #expect(repository.calls.map(\.following) == [true])
        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 4)
    }

    @Test func aFailureAfterAMidFlightTapSendsNothingMore() async {
        let (viewModel, repository) = makeSUT([.failure(UserFollowError.serverError(500))])
        let firstRequest = FollowGate()
        repository.beforeReturn = { _ in await firstRequest.wait() }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle("@alice", fallback: false)
        await firstRequest.open()
        await finish(viewModel)

        #expect(repository.calls.count == 1)
        #expect(!viewModel.isFollowing("@alice", fallback: false))
    }

    // MARK: - Profile loads

    @Test func whatTheViewerDidBeatsWhatTheFeedLoadedEarlier() async {
        let (viewModel, _) = makeSUT([.success(change(true, followers: 4))])

        viewModel.follow("@alice", fallback: false)
        await finish(viewModel)

        // Every clip of @alice the feed loaded before still says not followed.
        #expect(viewModel.isFollowing("@alice", fallback: false))
    }

    @Test func aProfileLoadThatStartedAfterTheLastAnswerReplacesWhatIsKnown() async {
        let (viewModel, _) = makeSUT([.success(change(true, followers: 4))])

        viewModel.toggle("@alice", fallback: false)
        await finish(viewModel)
        // Followed and unfollowed on another device since; this profile load is newer than the answer.
        let stamp = viewModel.stamp()
        viewModel.record("@alice", following: false, followerCount: 11, loadedAt: stamp)

        #expect(!viewModel.isFollowing("@alice", fallback: true))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 11)
    }

    @Test func aProfileLoadThatStartedBeforeTheLastAnswerIsIgnored() async {
        let (viewModel, _) = makeSUT([.success(change(true, followers: 4))])

        let stamp = viewModel.stamp()
        viewModel.toggle("@alice", fallback: false)
        await finish(viewModel)
        // The load may have been read before the follow was written.
        viewModel.record("@alice", following: false, followerCount: 3, loadedAt: stamp)

        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 4)
    }

    @Test func aProfileLoadIsIgnoredWhileAChangeIsOut() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 4))])
        let request = FollowGate()
        repository.beforeReturn = { _ in await request.wait() }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.record("@alice", following: false, followerCount: 3, loadedAt: viewModel.stamp())
        #expect(viewModel.isFollowing("@alice", fallback: false))

        await request.open()
        await finish(viewModel)
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 4)
    }

    @Test func anOlderProfileLoadNeverReplacesANewerOne() {
        let (viewModel, _) = makeSUT()
        let older = viewModel.stamp(), newer = viewModel.stamp()

        viewModel.record("@alice", following: true, followerCount: 6, loadedAt: newer)
        viewModel.record("@alice", following: false, followerCount: 5, loadedAt: older)

        #expect(viewModel.isFollowing("@alice", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 6)
    }

    /// What a profile loaded is also what the feed's "+" shows for that author's clips.
    @Test func aRecordedProfileSpeaksForTheFeedToo() {
        let (viewModel, _) = makeSUT()

        viewModel.record("@alice", following: true, followerCount: 2, loadedAt: viewModel.stamp())

        #expect(viewModel.isFollowing("@alice", fallback: false))
    }

    @Test func aRecordedNegativeCountShowsAsZero() {
        let (viewModel, _) = makeSUT()

        viewModel.record("@alice", following: false, followerCount: -4, loadedAt: viewModel.stamp())

        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 0)
    }

    // MARK: - Session change

    @Test func resetForgetsWhatTheViewerDidAndLoaded() async {
        let (viewModel, _) = makeSUT([.success(change(true, followers: 4))])

        viewModel.toggle("@alice", fallback: false)
        await finish(viewModel)
        viewModel.record("@bob", following: true, followerCount: 1, loadedAt: viewModel.stamp())
        viewModel.reset()

        #expect(!viewModel.isFollowing("@alice", fallback: false))
        #expect(!viewModel.isFollowing("@bob", fallback: false))
        #expect(viewModel.followerCount(of: "@alice", fallback: 3) == 3)
        #expect(!viewModel.isBusy)
    }

    @Test func aProfileLoadFromBeforeTheResetIsIgnored() {
        let (viewModel, _) = makeSUT()
        let stamp = viewModel.stamp()

        viewModel.reset()
        viewModel.record("@alice", following: true, followerCount: 2, loadedAt: stamp)

        #expect(!viewModel.isFollowing("@alice", fallback: false))
    }

    @Test func anAnswerThatArrivesAfterAResetChangesNothing() async {
        let (viewModel, repository) = makeSUT([.success(change(true, followers: 4, viewerFollows: 5))])
        let request = FollowGate()
        repository.beforeReturn = { _ in await request.wait() }
        var reported: [Int] = []
        viewModel.onViewerFollowingCountChange = { reported.append($0) }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.reset()
        #expect(!viewModel.isBusy)
        await request.open()
        // Give the late answer the time it would need to land.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!viewModel.isFollowing("@alice", fallback: false))
        #expect(reported.isEmpty, "the old session's count is not the new viewer's")
    }

    @Test func anOldAnswerDoesNotTouchWhatTheViewerDidAfterTheReset() async {
        let (viewModel, repository) = makeSUT([
            .success(change(true, followers: 40)),
            .success(change(true, followers: 6)),
        ])
        let oldRequest = FollowGate(), newRequest = FollowGate()
        repository.beforeReturn = { call in await (call == 1 ? oldRequest : newRequest).wait() }

        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 1 }
        viewModel.reset()
        viewModel.toggle("@alice", fallback: false)
        await waitUntil { repository.calls.count == 2 }

        await oldRequest.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == nil, "the old answer is not the viewer's now")
        #expect(viewModel.isBusy, "the new request is still out")

        await newRequest.open()
        await finish(viewModel)
        #expect(viewModel.followerCount(of: "@alice", fallback: nil) == 6)
        #expect(repository.calls.count == 2)
    }

    // MARK: - A follower or following list

    /// A list's rows carry whether the viewer followed each account when the list loaded. That word is only the
    /// fallback: once the viewer has touched an account, what they did wins over anything a list says afterwards.
    @Test func aListsWordIsOnlyTheFallbackForAnAccountTheViewerHasNotTouched() async {
        let (viewModel, repository) = makeSUT([.success(change(false, followers: 0, viewerFollows: 0))])

        // Nothing is known yet: the list's word is all there is, and "@Bob" is the same account as "@bob".
        #expect(viewModel.isFollowing("@bob", fallback: true))
        #expect(!viewModel.isFollowing("@Bob", fallback: false))

        viewModel.toggle("@bob", fallback: true)
        #expect(!viewModel.isFollowing("@bob", fallback: true))

        // A list loaded afterwards still says the viewer follows @bob. The tap beats it, before the answer and after.
        #expect(!viewModel.isFollowing("@bob", fallback: true))
        await finish(viewModel)
        #expect(!viewModel.isFollowing("@bob", fallback: true))
        #expect(repository.calls.map(\.following) == [false])
    }
}

/// Holds a stubbed request in flight until the test lets it go.
private actor FollowGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
