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
        result: Result<UserProfile, Error>,
        deleteResult: Result<Void, Error> = .success(())
    ) -> (ProfileViewModel, StubUserProfileRepository) {
        let repository = StubUserProfileRepository(result: result)
        repository.deleteResult = deleteResult
        let viewModel = ProfileViewModel(
            loadProfile: LoadUserProfileUseCase(repository: repository),
            deleteClip: DeleteUserClipUseCase(repository: repository),
            updateHandle: UpdateUserHandleUseCase(repository: repository)
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

    @Test func deleteRemovesClipAndDecrementsCount() async {
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        let profile = UserProfile(country: "TH", videoCount: 1, videos: [clip])
        let (viewModel, repository) = makeSUT(result: .success(profile))
        await viewModel.loadIfNeeded()

        await viewModel.delete(clip)

        #expect(repository.deletedIDs == [clip.id])
        #expect(viewModel.clips.isEmpty)
        #expect(viewModel.profile?.videoCount == 0)
        #expect(viewModel.deleteErrorMessage == nil)
    }

    @Test func deleteFailureSurfacesMessageAndKeepsClip() async {
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        let profile = UserProfile(country: "TH", videoCount: 1, videos: [clip])
        let (viewModel, _) = makeSUT(
            result: .success(profile),
            deleteResult: .failure(StubError.feedFailed)
        )
        await viewModel.loadIfNeeded()

        await viewModel.delete(clip)

        #expect(viewModel.clips.count == 1)
        #expect(viewModel.deleteErrorMessage == "feed failed")

        viewModel.clearDeleteError()
        #expect(viewModel.deleteErrorMessage == nil)
    }

    @Test func updateHandleSavesAndReflectsNewValue() async {
        let profile = UserProfile(handle: "@old", country: "TH", videoCount: 0)
        let (viewModel, repository) = makeSUT(result: .success(profile))
        repository.updateHandleResult = .success("@new")
        await viewModel.loadIfNeeded()

        let didSave = await viewModel.updateHandle("@new")

        #expect(didSave)
        #expect(repository.updatedHandles == ["@new"])
        #expect(viewModel.handle == "@new")
        #expect(viewModel.handleErrorMessage == nil)
    }

    @Test func updateHandleFailureSurfacesMessage() async {
        let profile = UserProfile(handle: "@old", country: "TH", videoCount: 0)
        let (viewModel, repository) = makeSUT(result: .success(profile))
        repository.updateHandleResult = .failure(StubError.feedFailed)
        await viewModel.loadIfNeeded()

        let didSave = await viewModel.updateHandle("@taken")

        #expect(!didSave)
        #expect(viewModel.handle == "@old")
        #expect(viewModel.handleErrorMessage != nil)

        viewModel.clearHandleError()
        #expect(viewModel.handleErrorMessage == nil)
    }
}
