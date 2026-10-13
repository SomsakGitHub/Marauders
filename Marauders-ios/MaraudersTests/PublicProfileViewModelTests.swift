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
}
