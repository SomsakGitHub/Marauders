//
//  ProfileViewModelTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct ProfileViewModelTests {
    private func makeSUT(
        result: Result<UserProfile, Error>
    ) -> (ProfileViewModel, StubUserProfileRepository) {
        let repository = StubUserProfileRepository(result: result)
        let viewModel = ProfileViewModel(
            loadProfile: LoadUserProfileUseCase(repository: repository)
        )
        return (viewModel, repository)
    }

    @Test func loadTransitionsToLoadedWithClips() async {
        let profile = UserProfile(
            country: "TH",
            videoCount: 1,
            videos: [
                FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
            ]
        )
        let (viewModel, repository) = makeSUT(result: .success(profile))

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.profile == profile)
        #expect(viewModel.clips.count == 1)
        #expect(repository.fetchCount == 1)
    }

    @Test func loadFailureExposesMessage() async {
        let (viewModel, _) = makeSUT(result: .failure(StubError.feedFailed))

        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .failed("feed failed"))
        #expect(viewModel.profile == nil)
    }

    @Test func loadIfNeededOnlyFetchesOnce() async {
        let (viewModel, repository) = makeSUT(result: .success(UserProfile()))

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(repository.fetchCount == 1)
    }

    @Test func reloadFetchesAgain() async {
        let (viewModel, repository) = makeSUT(result: .success(UserProfile()))

        await viewModel.loadIfNeeded()
        await viewModel.reload()

        #expect(repository.fetchCount == 2)
    }
}
