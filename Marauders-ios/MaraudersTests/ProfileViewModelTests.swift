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
        deleteResult: Result<Void, Error> = .success(()),
        imagePreparer: StubAvatarImagePreparer = StubAvatarImagePreparer()
    ) -> (ProfileViewModel, StubUserProfileRepository) {
        let repository = StubUserProfileRepository(result: result)
        repository.deleteResult = deleteResult
        let viewModel = ProfileViewModel(
            loadProfile: LoadUserProfileUseCase(repository: repository),
            deleteClip: DeleteUserClipUseCase(repository: repository),
            updateHandle: UpdateUserHandleUseCase(repository: repository),
            updateAvatar: UpdateAvatarUseCase(repository: repository, imagePreparer: imagePreparer)
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

    @Test func deleteTellsTheFeedWhichClipWentOnlyWhenTheServerDeletedIt() async {
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        let profile = UserProfile(country: "TH", videoCount: 1, videos: [clip])
        let (viewModel, _) = makeSUT(result: .success(profile))
        await viewModel.loadIfNeeded()
        var deleted: [UUID] = []
        viewModel.onClipDeleted = { deleted.append($0) }

        await viewModel.delete(clip)
        #expect(deleted == [clip.id])

        let (failing, _) = makeSUT(result: .success(profile), deleteResult: .failure(StubError.feedFailed))
        await failing.loadIfNeeded()
        var failedDeletes: [UUID] = []
        failing.onClipDeleted = { failedDeletes.append($0) }
        await failing.delete(clip)
        #expect(failedDeletes.isEmpty)
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

    @Test func updateHandleNotifiesObserver() async {
        let profile = UserProfile(handle: "@old", country: "TH", videoCount: 0)
        let (viewModel, repository) = makeSUT(result: .success(profile))
        repository.updateHandleResult = .success("@new")
        await viewModel.loadIfNeeded()

        var observed: (old: String, new: String)?
        viewModel.onHandleChanged = { observed = ($0, $1) }

        _ = await viewModel.updateHandle("@new")

        #expect(observed?.old == "@old")
        #expect(observed?.new == "@new")
    }

    @Test func updateHandleFailureDoesNotNotifyObserver() async {
        let profile = UserProfile(handle: "@old", country: "TH", videoCount: 0)
        let (viewModel, repository) = makeSUT(result: .success(profile))
        repository.updateHandleResult = .failure(StubError.feedFailed)
        await viewModel.loadIfNeeded()

        var notified = false
        viewModel.onHandleChanged = { _, _ in notified = true }

        _ = await viewModel.updateHandle("@taken")

        #expect(!notified)
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

    @Test func updateAvatarUploadsPreparedJPEGAndUpdatesProfile() async {
        let profile = UserProfile(handle: "@me", country: "TH", videoCount: 0)
        let prepared = Data([0x01, 0x02, 0x03])
        let (viewModel, repository) = makeSUT(
            result: .success(profile),
            imagePreparer: StubAvatarImagePreparer(result: prepared)
        )
        repository.updateAvatarResult = .success(URL(string: "https://cdn.example.com/a.jpg")!)
        await viewModel.loadIfNeeded()

        let didSave = await viewModel.updateAvatar(rawImageData: Data([0xAA, 0xBB]))

        #expect(didSave)
        #expect(repository.updatedAvatars.count == 1)
        #expect(repository.updatedAvatars.first?.imageData == prepared)
        #expect(repository.updatedAvatars.first?.mimeType == "image/jpeg")
        #expect(viewModel.profile?.avatarURL == URL(string: "https://cdn.example.com/a.jpg"))
        #expect(viewModel.avatarErrorMessage == nil)
    }

    @Test func updateAvatarNotifiesObserverWithURLAndHandle() async {
        let profile = UserProfile(handle: "@me", country: "TH", videoCount: 0)
        let (viewModel, repository) = makeSUT(result: .success(profile))
        repository.updateAvatarResult = .success(URL(string: "https://cdn.example.com/a.jpg")!)
        await viewModel.loadIfNeeded()

        var observed: (url: URL, handle: String)?
        viewModel.onAvatarChanged = { observed = ($0, $1) }

        _ = await viewModel.updateAvatar(rawImageData: Data([0xAA]))

        #expect(observed?.url == URL(string: "https://cdn.example.com/a.jpg"))
        #expect(observed?.handle == "@me")
    }

    @Test func updateAvatarUnreadableImageSurfacesMessage() async {
        let profile = UserProfile(handle: "@me", country: "TH", videoCount: 0)
        let (viewModel, repository) = makeSUT(
            result: .success(profile),
            imagePreparer: StubAvatarImagePreparer(result: nil)
        )
        await viewModel.loadIfNeeded()

        let didSave = await viewModel.updateAvatar(rawImageData: Data([0xAA]))

        #expect(!didSave)
        #expect(repository.updatedAvatars.isEmpty)
        #expect(viewModel.avatarErrorMessage != nil)

        viewModel.clearAvatarError()
        #expect(viewModel.avatarErrorMessage == nil)
    }

    @Test func updateAvatarFailureSurfacesMessage() async {
        let profile = UserProfile(handle: "@me", country: "TH", videoCount: 0)
        let (viewModel, repository) = makeSUT(result: .success(profile))
        repository.updateAvatarResult = .failure(StubError.feedFailed)
        await viewModel.loadIfNeeded()

        let didSave = await viewModel.updateAvatar(rawImageData: Data([0xAA]))

        #expect(!didSave)
        #expect(viewModel.avatarErrorMessage == "feed failed")
    }
}
