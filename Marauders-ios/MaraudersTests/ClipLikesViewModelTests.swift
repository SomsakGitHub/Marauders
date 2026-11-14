//
//  ClipLikesViewModelTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct ClipLikesViewModelTests {
    private static let url = URL(string: "https://cdn.example.com/a.mp4")!

    private func clip(_ count: Int? = 3, liked: Bool? = false, id: UUID = UUID()) -> FeedVideo {
        FeedVideo(id: id, streamURL: Self.url, likeCount: count, likedByViewer: liked)
    }

    private func makeSUT(
        _ results: [Result<ClipLikeState, Error>] = [.success(ClipLikeState(liked: true, count: 4))]
    ) -> (ClipLikesViewModel, StubClipLikeRepository) {
        let repository = StubClipLikeRepository(results: results)
        return (ClipLikesViewModel(setLike: SetClipLikeUseCase(repository: repository)), repository)
    }

    /// Waits, for up to two seconds, for work the view model starts as a task of its own.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finish(_ viewModel: ClipLikesViewModel) async {
        await waitUntil { !viewModel.isBusy }
    }

    // MARK: - What the feed says

    @Test func aClipNobodyHasTouchedShowsWhatTheFeedSaid() {
        let (viewModel, repository) = makeSUT()

        #expect(viewModel.state(for: clip(12, liked: true)) == ClipLikeState(liked: true, count: 12))
        #expect(viewModel.state(for: clip(0, liked: false)) == ClipLikeState(liked: false, count: 0))
        #expect(repository.calls.isEmpty)
    }

    /// A Worker that predates likes sends neither field.
    @Test func aFeedWithoutLikeFieldsShowsNoLikes() {
        let (viewModel, _) = makeSUT()

        #expect(viewModel.state(for: clip(nil, liked: nil)) == ClipLikeState(liked: false, count: 0))
    }

    // MARK: - Tapping

    @Test func aTapShowsTheLikeAtOnceAndTheWorkersCountReplacesTheGuess() async {
        let (viewModel, repository) = makeSUT([.success(ClipLikeState(liked: true, count: 7))])
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        // Nothing has been answered yet: this is the viewer's own guess.
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))
        #expect(viewModel.isBusy)

        await finish(viewModel)

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 7))
        #expect(repository.calls.map(\.liked) == [true])
        #expect(repository.calls.map(\.videoID) == [clip.id])
    }

    @Test func tappingALikedClipTakesTheLikeBack() async {
        let (viewModel, repository) = makeSUT([.success(ClipLikeState(liked: false, count: 4))])
        let clip = clip(5, liked: true)

        viewModel.toggle(clip)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 4))

        await finish(viewModel)

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 4))
        #expect(repository.calls.map(\.liked) == [false])
    }

    @Test func theGuessNeverShowsAnEmptyHeartWithANegativeCount() {
        let (viewModel, _) = makeSUT()
        // A feed that says liked while counting none cannot be right, but the screen must not show -1.
        let clip = clip(0, liked: true)

        viewModel.toggle(clip)

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 0))
    }

    @Test func clipsAreLikedIndependently() async {
        let (viewModel, repository) = makeSUT([
            .success(ClipLikeState(liked: true, count: 1)),
            .success(ClipLikeState(liked: true, count: 9)),
        ])
        let first = clip(0), second = clip(8)

        viewModel.toggle(first)
        viewModel.toggle(second)
        await finish(viewModel)

        #expect(Set(repository.calls.map(\.videoID)) == [first.id, second.id])
        #expect(viewModel.state(for: first).liked)
        #expect(viewModel.state(for: second).liked)
        #expect(viewModel.state(for: clip(3, liked: false)) == ClipLikeState(liked: false, count: 3))
    }

    // MARK: - Failures

    @Test(arguments: [
        ClipLikeError.serverError(500), .rateLimited, .notFound, .signInRequired, .invalidResponse,
    ])
    func aFailureGoesBackToWhatTheFeedSaid(error: ClipLikeError) async {
        let (viewModel, _) = makeSUT([.failure(error)])
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await finish(viewModel)

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 3))
        #expect(!viewModel.isBusy)
    }

    @Test func aFailureGoesBackToTheWorkersLastAnswer() async {
        let (viewModel, _) = makeSUT([
            .success(ClipLikeState(liked: true, count: 9)),
            .failure(ClipLikeError.serverError(503)),
        ])
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await finish(viewModel)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 9))

        viewModel.toggle(clip)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 8))
        await finish(viewModel)

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 9))
    }

    @Test func aTapAfterAFailureTriesAgain() async {
        let (viewModel, repository) = makeSUT([
            .failure(ClipLikeError.serverError(500)),
            .success(ClipLikeState(liked: true, count: 4)),
        ])
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await finish(viewModel)
        viewModel.toggle(clip)
        await finish(viewModel)

        #expect(repository.calls.map(\.liked) == [true, true])
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))
    }

    // MARK: - Taps while a request is out

    @Test func aSecondTapWhileTheFirstIsOutIsSentAfterItAndLeavesOneRequestOutAtATime() async {
        let (viewModel, repository) = makeSUT([
            .success(ClipLikeState(liked: true, count: 4)),
            .success(ClipLikeState(liked: false, count: 3)),
        ])
        let firstRequest = Gate(), secondRequest = Gate()
        repository.beforeReturn = { call in await (call == 1 ? firstRequest : secondRequest).wait() }
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle(clip)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 3))
        #expect(repository.calls.count == 1, "the second tap must wait for the first request")

        await firstRequest.open()
        await waitUntil { repository.calls.count == 2 }
        // The Worker said 4 with the like; without it that is 3.
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 3))
        await secondRequest.open()
        await finish(viewModel)

        #expect(repository.calls.map(\.liked) == [true, false])
        #expect(repository.peakConcurrency == 1)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 3))
    }

    /// Like, unlike, like again before the first answer: the Worker already holds what the viewer ended on.
    @Test func tapsThatEndWhereTheRequestWentSendNothingMore() async {
        let (viewModel, repository) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let firstRequest = Gate()
        repository.beforeReturn = { _ in await firstRequest.wait() }
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle(clip)
        viewModel.toggle(clip)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))

        await firstRequest.open()
        await finish(viewModel)

        #expect(repository.calls.map(\.liked) == [true])
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))
    }

    @Test func aFailureAfterAMidFlightTapSendsNothingMore() async {
        let (viewModel, repository) = makeSUT([.failure(ClipLikeError.serverError(500))])
        let firstRequest = Gate()
        repository.beforeReturn = { _ in await firstRequest.wait() }
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle(clip)
        await firstRequest.open()
        await finish(viewModel)

        #expect(repository.calls.count == 1)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 3))
    }

    @Test func aNegativeCountFromTheFeedShowsAsZero() {
        let (viewModel, _) = makeSUT()

        #expect(viewModel.state(for: clip(-5, liked: false)) == ClipLikeState(liked: false, count: 0))
    }

    /// A Worker answer that contradicts itself (liked, with none counted) must not draw a negative count either.
    @Test func aMidFlightGuessOnAnAnswerCountingNoneStaysAtZero() async {
        let (viewModel, repository) = makeSUT([
            .success(ClipLikeState(liked: true, count: 0)),
            .success(ClipLikeState(liked: false, count: 0)),
        ])
        let firstRequest = Gate(), secondRequest = Gate()
        repository.beforeReturn = { call in await (call == 1 ? firstRequest : secondRequest).wait() }
        let clip = clip(0, liked: false)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.toggle(clip)
        await firstRequest.open()
        await waitUntil { repository.calls.count == 2 }
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 0))

        await secondRequest.open()
        await finish(viewModel)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 0))
    }

    // MARK: - When the feed moves on

    @Test func aFeedReloadThatSaysSomethingElseWinsOverWhatTheViewerDid() async {
        let (viewModel, repository) = makeSUT([
            .success(ClipLikeState(liked: true, count: 4)),
            .success(ClipLikeState(liked: false, count: 9)),
        ])
        let id = UUID()
        let before = clip(3, liked: false, id: id)

        viewModel.toggle(before)
        await finish(viewModel)
        #expect(viewModel.state(for: before) == ClipLikeState(liked: true, count: 4))

        // The same clip after a reload: other viewers liked it meanwhile.
        let after = clip(10, liked: true, id: id)
        #expect(viewModel.state(for: after) == ClipLikeState(liked: true, count: 10))

        // The next tap starts from what the reload said.
        viewModel.toggle(after)
        #expect(viewModel.state(for: after) == ClipLikeState(liked: false, count: 9))
        await finish(viewModel)
        #expect(viewModel.state(for: after) == ClipLikeState(liked: false, count: 9))
        #expect(repository.calls.map(\.liked) == [true, false])
    }

    @Test func aReloadWithTheSameNumbersKeepsWhatTheViewerDid() async {
        let (viewModel, _) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let id = UUID()

        viewModel.toggle(clip(3, liked: false, id: id))
        await finish(viewModel)

        #expect(viewModel.state(for: clip(3, liked: false, id: id)) == ClipLikeState(liked: true, count: 4))
    }

    /// Either number moving is enough to show the reload is newer than what the viewer did.
    @Test func aReloadThatChangesOnlyTheCountWinsOverWhatTheViewerDid() async {
        let (viewModel, _) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let id = UUID()

        viewModel.toggle(clip(3, liked: false, id: id))
        await finish(viewModel)

        #expect(viewModel.state(for: clip(8, liked: false, id: id)) == ClipLikeState(liked: false, count: 8))
    }

    @Test func aReloadThatChangesOnlyTheLikedFlagWinsOverWhatTheViewerDid() async {
        let (viewModel, _) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let id = UUID()

        viewModel.toggle(clip(3, liked: false, id: id))
        await finish(viewModel)

        #expect(viewModel.state(for: clip(3, liked: true, id: id)) == ClipLikeState(liked: true, count: 3))
    }

    // MARK: - Session change

    @Test func resetForgetsWhatTheViewerDid() async {
        let (viewModel, _) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await finish(viewModel)
        viewModel.reset()

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 3))
        #expect(!viewModel.isBusy)
    }

    @Test func anAnswerThatArrivesAfterAResetChangesNothing() async {
        let (viewModel, repository) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let firstRequest = Gate()
        repository.beforeReturn = { _ in await firstRequest.wait() }
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.reset()
        #expect(!viewModel.isBusy)
        await firstRequest.open()
        // Give the late answer the time it would need to land.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: false, count: 3))
        #expect(!viewModel.isBusy)
    }

    @Test func anOldAnswerDoesNotTouchWhatTheViewerDidAfterTheReset() async {
        let (viewModel, repository) = makeSUT([
            .success(ClipLikeState(liked: true, count: 40)),
            .success(ClipLikeState(liked: true, count: 6)),
        ])
        let oldRequest = Gate(), newRequest = Gate()
        repository.beforeReturn = { call in await (call == 1 ? oldRequest : newRequest).wait() }
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.reset()
        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 2 }
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))

        // The old request lands first, while the new one is still out.
        await oldRequest.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(
            viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4), "the old answer is not the viewer's now"
        )
        #expect(viewModel.isBusy, "the new request is still out")

        await newRequest.open()
        await finish(viewModel)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 6))
        #expect(repository.calls.count == 2)
    }

    @Test func anOldFailureDoesNotTouchWhatTheViewerDidAfterTheReset() async {
        let (viewModel, repository) = makeSUT([
            .failure(ClipLikeError.serverError(500)),
            .success(ClipLikeState(liked: true, count: 6)),
        ])
        let oldRequest = Gate(), newRequest = Gate()
        repository.beforeReturn = { call in await (call == 1 ? oldRequest : newRequest).wait() }
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.reset()
        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 2 }

        // The old request fails while the new one is still out: it has no say over the new tap.
        await oldRequest.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(
            viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4),
            "the old failure is not the viewer's now")
        #expect(viewModel.isBusy, "the new request is still out")

        await newRequest.open()
        await finish(viewModel)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 6))
    }

    /// The task of the first tap has not started when the viewer signs out and taps again; only the new one may send.
    @Test func aTapRightAfterAResetSendsOneRequestNotTwo() async {
        let (viewModel, repository) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let request = Gate()
        repository.beforeReturn = { _ in await request.wait() }
        let clip = clip(3, liked: false)

        viewModel.toggle(clip)
        viewModel.reset()
        viewModel.toggle(clip)
        await waitUntil { repository.calls.count >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(repository.calls.count == 1)
        #expect(viewModel.isBusy, "the request of the new tap is still out")

        await request.open()
        await finish(viewModel)
        #expect(repository.calls.count == 1)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))
    }

    // MARK: - Double tap

    @Test func aDoubleTapLikesAClipTheViewerDoesNotLikeYet() async {
        let (viewModel, repository) = makeSUT([.success(ClipLikeState(liked: true, count: 7))])
        let clip = clip(3, liked: false)

        viewModel.like(clip)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))

        await finish(viewModel)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 7))
        #expect(repository.calls.map(\.liked) == [true])
    }

    @Test func aDoubleTapNeverTakesALikeBack() {
        let (viewModel, repository) = makeSUT()
        let clip = clip(5, liked: true)

        viewModel.like(clip)

        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 5))
        #expect(!viewModel.isBusy)
        #expect(repository.calls.isEmpty)
    }

    /// A run of hearts on a clip the viewer has just liked sends the one like, not one per heart.
    @Test func moreDoubleTapsAfterALikeSendNothingMore() async {
        let (viewModel, repository) = makeSUT([.success(ClipLikeState(liked: true, count: 4))])
        let request = Gate()
        repository.beforeReturn = { _ in await request.wait() }
        let clip = clip(3, liked: false)

        viewModel.like(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.like(clip)
        viewModel.like(clip)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))

        await request.open()
        await finish(viewModel)
        #expect(repository.calls.map(\.liked) == [true])
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 4))
    }

    /// The viewer took the like back with the heart and double-tapped before the Worker answered: the clip ends liked.
    @Test func aDoubleTapWhileAnUnlikeIsOutLikesTheClipAgain() async {
        let (viewModel, repository) = makeSUT([
            .success(ClipLikeState(liked: false, count: 4)),
            .success(ClipLikeState(liked: true, count: 5)),
        ])
        let firstRequest = Gate()
        repository.beforeReturn = { call in if call == 1 { await firstRequest.wait() } }
        let clip = clip(5, liked: true)

        viewModel.toggle(clip)
        await waitUntil { repository.calls.count == 1 }
        viewModel.like(clip)
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 5))

        await firstRequest.open()
        await finish(viewModel)
        #expect(repository.calls.map(\.liked) == [false, true])
        #expect(viewModel.state(for: clip) == ClipLikeState(liked: true, count: 5))
    }
}

/// Holds a stubbed request in flight until the test lets it go.
private actor Gate {
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
