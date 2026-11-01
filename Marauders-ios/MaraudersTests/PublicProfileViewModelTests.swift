//
//  PublicProfileViewModelTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct PublicProfileViewModelTests {
    private func makeSUT(
        handle: String = "@friend",
        result: Result<PublicUserProfile, Error>
    ) -> (PublicProfileViewModel, StubUserProfileRepository) {
        let repository = StubUserProfileRepository(result: .success(UserProfile()))
        repository.publicResult = result
        let viewModel = PublicProfileViewModel(
            handle: handle,
            loadProfile: LoadPublicProfileUseCase(repository: repository)
        )
        return (viewModel, repository)
    }

    @Test func loadTransitionsToLoadedWithClips() async {
        let profile = PublicUserProfile(
            handle: "@friend",
            country: "TH",
            videoCount: 2,
            videos: [
                FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
            ]
        )
        let (viewModel, repository) = makeSUT(result: .success(profile))

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.profile == profile)
        #expect(viewModel.clips.count == 1)
        #expect(repository.requestedHandles == ["@friend"])
    }

    @Test func loadFailureExposesMessage() async {
        let (viewModel, _) = makeSUT(result: .failure(StubError.feedFailed))

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .failed("feed failed"))
        #expect(viewModel.profile == nil)
    }

    @Test func loadIfNeededOnlyLoadsOnce() async {
        let (viewModel, repository) = makeSUT(result: .success(PublicUserProfile(handle: "@friend")))

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(repository.requestedHandles.count == 1)
    }

    @Test func reloadFetchesAgain() async {
        let (viewModel, repository) = makeSUT(result: .success(PublicUserProfile(handle: "@friend")))

        await viewModel.loadIfNeeded()
        await viewModel.reload()

        #expect(repository.requestedHandles.count == 2)
    }

    // MARK: - Follow

    private func friend(following: Bool? = false, followers: Int? = 3, isViewer: Bool? = false) -> PublicUserProfile {
        PublicUserProfile(
            handle: "@friend", followerCount: followers, followingCount: followers == nil ? nil : 5,
            followedByViewer: following, isViewer: isViewer
        )
    }

    private func makeFollowingSUT(
        _ profile: PublicUserProfile,
        results: [Result<UserFollowChange, Error>] = [
            .success(UserFollowChange(following: true, followerCount: 4, viewerFollowingCount: 1)),
        ]
    ) -> (PublicProfileViewModel, UserFollowsViewModel, StubUserFollowRepository) {
        let profiles = StubUserProfileRepository(result: .success(UserProfile()))
        profiles.publicResult = .success(profile)
        let followRepository = StubUserFollowRepository(results: results)
        let follows = UserFollowsViewModel(setFollow: SetUserFollowUseCase(repository: followRepository))
        let viewModel = PublicProfileViewModel(
            handle: "@friend", loadProfile: LoadPublicProfileUseCase(repository: profiles), follows: follows
        )
        return (viewModel, follows, followRepository)
    }

    private func waitUntilIdle(_ follows: UserFollowsViewModel) async {
        for _ in 0 ..< 200 where follows.isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func someoneElsesProfileOffersFollowWithTheLoadedState() async {
        let (viewModel, _, _) = makeFollowingSUT(friend(following: false, followers: 3))

        await viewModel.loadIfNeeded()

        #expect(viewModel.canFollow)
        #expect(!viewModel.isFollowing)
        #expect(viewModel.followerCount == 3)
    }

    @Test func theViewersOwnProfileOffersNoFollow() async {
        let (viewModel, follows, _) = makeFollowingSUT(friend(isViewer: true))

        await viewModel.loadIfNeeded()
        viewModel.toggleFollow()

        #expect(!viewModel.canFollow)
        #expect(!follows.isBusy)
    }

    /// A Worker that predates follows sends no follow fields, and would refuse the request anyway.
    @Test func aProfileFromAWorkerWithoutFollowsOffersNoFollow() async {
        let (viewModel, _, _) = makeFollowingSUT(friend(following: nil, followers: nil, isViewer: nil))

        await viewModel.loadIfNeeded()

        #expect(!viewModel.canFollow)
        #expect(viewModel.followerCount == nil)
    }

    @Test func withoutTheSharedFollowsThereIsNoFollow() async {
        let (viewModel, _) = makeSUT(result: .success(friend()))

        await viewModel.loadIfNeeded()

        #expect(!viewModel.canFollow)
        #expect(viewModel.followerCount == 3)
    }

    @Test func followingShowsAtOnceAndTheWorkersCountOnceItAnswers() async {
        let (viewModel, follows, repository) = makeFollowingSUT(friend(following: false, followers: 3), results: [
            .success(UserFollowChange(following: true, followerCount: 10, viewerFollowingCount: 1)),
        ])
        await viewModel.loadIfNeeded()

        viewModel.toggleFollow()
        #expect(viewModel.isFollowing)
        #expect(viewModel.followerCount == 4)

        await waitUntilIdle(follows)
        #expect(viewModel.isFollowing)
        #expect(viewModel.followerCount == 10)
        #expect(repository.calls.map(\.handle) == ["@friend"])
        #expect(repository.calls.map(\.following) == [true])
    }

    @Test func tappingFollowingStopsTheFollow() async {
        let (viewModel, follows, repository) = makeFollowingSUT(friend(following: true, followers: 3), results: [
            .success(UserFollowChange(following: false, followerCount: 2, viewerFollowingCount: 0)),
        ])
        await viewModel.loadIfNeeded()

        viewModel.toggleFollow()
        await waitUntilIdle(follows)

        #expect(!viewModel.isFollowing)
        #expect(viewModel.followerCount == 2)
        #expect(repository.calls.map(\.following) == [false])
    }

    /// The feed's clips by this author say what the feed loaded; the profile's newer word is what their "+" shows.
    @Test func aLoadTellsTheFeedWhatTheWorkerSaysNow() async {
        let (viewModel, follows, _) = makeFollowingSUT(friend(following: true, followers: 3))

        await viewModel.loadIfNeeded()

        #expect(follows.isFollowing("@friend", fallback: false))
    }

    /// The reload after a sign-in can overtake a pull to refresh that started before it; the earlier load's answer is
    /// the older one and must not replace the newer.
    @Test func anOlderLoadThatAnswersLastDoesNotReplaceTheNewerOne() async {
        let repository = OverlappingProfileRepository(answers: [friend(following: false), friend(following: true)])
        let viewModel = PublicProfileViewModel(handle: "@friend", loadProfile: LoadPublicProfileUseCase(repository: repository))

        let older = Task { await viewModel.reload() }
        for _ in 0 ..< 200 where repository.requests < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await viewModel.reload()
        #expect(viewModel.profile?.followedByViewer == true)

        await repository.letTheFirstAnswerThrough()
        await older.value

        #expect(viewModel.profile?.followedByViewer == true)
        #expect(viewModel.state == .loaded)
    }

    @Test func aFollowMadeFromTheFeedShowsOnTheProfile() async {
        let (viewModel, follows, _) = makeFollowingSUT(friend(following: false, followers: 3))
        await viewModel.loadIfNeeded()

        follows.follow("@friend", fallback: false)

        #expect(viewModel.isFollowing)
        await waitUntilIdle(follows)
        #expect(viewModel.followerCount == 4)
    }
}

/// Answers public profile loads in order, holding the first one until the test lets it through.
private final class OverlappingProfileRepository: UserProfileRepository, @unchecked Sendable {
    private let answers: [PublicUserProfile]
    private let firstAnswer = ProfileLoadGate()
    private(set) var requests = 0

    init(answers: [PublicUserProfile]) {
        self.answers = answers
    }

    func letTheFirstAnswerThrough() async {
        await firstAnswer.open()
    }

    func fetchPublicProfile(handle: String) async throws -> PublicUserProfile {
        requests += 1
        let call = requests
        if call == 1 { await firstAnswer.wait() }
        return answers[min(call, answers.count) - 1]
    }

    func fetchProfile() async throws -> UserProfile { UserProfile() }
    func updateHandle(_ handle: String) async throws -> String { handle }
    func updateAvatar(imageData: Data, mimeType: String) async throws -> URL { URL(string: "https://example.com/a.jpg")! }
    func deleteClip(id: UUID) async throws {}
}

private actor ProfileLoadGate {
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
