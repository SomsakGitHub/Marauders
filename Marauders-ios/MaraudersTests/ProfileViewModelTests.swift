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
        imagePreparer: StubAvatarImagePreparer = StubAvatarImagePreparer(),
        gate: ProfileRequestGate? = nil
    ) -> (ProfileViewModel, StubUserProfileRepository) {
        let repository = StubUserProfileRepository(result: result)
        repository.deleteResult = deleteResult
        let served: UserProfileRepository = gate.map { GatedProfileRepository(base: repository, gate: $0) } ?? repository
        let viewModel = ProfileViewModel(
            loadProfile: LoadUserProfileUseCase(repository: served),
            deleteClip: DeleteUserClipUseCase(repository: served),
            updateHandle: UpdateUserHandleUseCase(repository: served),
            updateAvatar: UpdateAvatarUseCase(repository: served, imagePreparer: imagePreparer)
        )
        return (viewModel, repository)
    }

    /// Starts `operation`, ends the session while its request is still out, optionally signs in as someone else whose
    /// profile loads at once, and only then lets the old request finish.
    private func endSessionWhileOut(
        _ viewModel: ProfileViewModel,
        _ repository: StubUserProfileRepository,
        _ gate: ProfileRequestGate,
        thenSignInAs next: UserProfile? = nil,
        during operation: @escaping @MainActor () async -> Void
    ) async {
        await gate.holdNextRequest()
        let running = Task { await operation() }
        await gate.waitUntilHeld()
        viewModel.resetForSessionChange()
        if let next {
            repository.result = .success(next)
            await viewModel.loadIfNeeded()
        }
        await gate.release()
        await running.value
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

    // MARK: - The session ends

    @Test func resetForgetsTheLoadedProfileSoTheNextSessionLoadsItsOwn() async {
        let (viewModel, repository) = makeSUT(result: .success(UserProfile(handle: "@first", country: "TH")))
        await viewModel.loadIfNeeded()

        viewModel.resetForSessionChange()

        #expect(viewModel.profile == nil)
        #expect(viewModel.state == .idle)
        repository.result = .success(UserProfile(handle: "@second", country: "JP"))
        await viewModel.loadIfNeeded()
        #expect(viewModel.profile?.handle == "@second")
        #expect(repository.fetchCount == 2)
    }

    @Test func resetForgetsAFailedLoadSoTheNextSessionTriesAgain() async {
        // A 401 ends the session as the load fails; without the reset its error would greet the next sign-in.
        let (viewModel, repository) = makeSUT(result: .failure(StubError.feedFailed))
        await viewModel.loadIfNeeded()
        #expect(viewModel.state == .failed("feed failed"))

        viewModel.resetForSessionChange()
        repository.result = .success(UserProfile(handle: "@me"))
        await viewModel.loadIfNeeded()

        #expect(viewModel.state == .loaded)
        #expect(repository.fetchCount == 2)
    }

    @Test func resetClearsTheMessagesOfTheEndedSession() async {
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        let (viewModel, repository) = makeSUT(
            result: .success(UserProfile(country: "TH", videoCount: 1, videos: [clip])),
            deleteResult: .failure(StubError.feedFailed)
        )
        repository.updateHandleResult = .failure(StubError.feedFailed)
        repository.updateAvatarResult = .failure(StubError.feedFailed)
        await viewModel.loadIfNeeded()
        await viewModel.delete(clip)
        _ = await viewModel.updateHandle("@taken")
        _ = await viewModel.updateAvatar(rawImageData: Data([0xAA]))
        #expect(viewModel.deleteErrorMessage != nil)
        #expect(viewModel.handleErrorMessage != nil)
        #expect(viewModel.avatarErrorMessage != nil)

        viewModel.resetForSessionChange()

        #expect(viewModel.deleteErrorMessage == nil)
        #expect(viewModel.handleErrorMessage == nil)
        #expect(viewModel.avatarErrorMessage == nil)
    }

    @Test func resetFreesTheAvatarButtonWhileAnUploadOfTheEndedSessionIsStillOut() async {
        let gate = ProfileRequestGate()
        let (viewModel, _) = makeSUT(result: .success(UserProfile(handle: "@first")), gate: gate)
        await viewModel.loadIfNeeded()
        await gate.holdNextRequest()
        let upload = Task { await viewModel.updateAvatar(rawImageData: Data([0xAA])) }
        await gate.waitUntilHeld()
        #expect(viewModel.isUpdatingAvatar)

        viewModel.resetForSessionChange()
        #expect(!viewModel.isUpdatingAvatar)

        await gate.release()
        _ = await upload.value
        #expect(!viewModel.isUpdatingAvatar)
    }

    @Test func aLoadStillOutWhenTheSessionEndsCannotFillTheProfileAfterwards() async {
        let gate = ProfileRequestGate()
        let (viewModel, repository) = makeSUT(result: .success(UserProfile(handle: "@first")), gate: gate)

        await endSessionWhileOut(viewModel, repository, gate) { await viewModel.loadIfNeeded() }

        #expect(viewModel.profile == nil)
        #expect(viewModel.state == .idle)
    }

    @Test func aLoadThatFailsAfterTheSessionEndedLeavesNoErrorBehind() async {
        let gate = ProfileRequestGate()
        let (viewModel, repository) = makeSUT(result: .failure(StubError.feedFailed), gate: gate)

        await endSessionWhileOut(viewModel, repository, gate) { await viewModel.loadIfNeeded() }

        #expect(viewModel.state == .idle)
    }

    @Test func anOlderLoadFinishingLastCannotReplaceTheNextSessionsProfile() async {
        let gate = ProfileRequestGate()
        let (viewModel, repository) = makeSUT(result: .success(UserProfile(handle: "@first")), gate: gate)

        await endSessionWhileOut(viewModel, repository, gate, thenSignInAs: UserProfile(handle: "@second")) {
            await viewModel.loadIfNeeded()
        }

        #expect(viewModel.profile?.handle == "@second")
        #expect(viewModel.state == .loaded)
    }

    @Test func requestsThatFailAfterTheSessionEndedLeaveNoMessageBehind() async {
        let gate = ProfileRequestGate()
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        let (viewModel, repository) = makeSUT(
            result: .success(UserProfile(country: "TH", videoCount: 1, videos: [clip])),
            deleteResult: .failure(StubError.feedFailed),
            gate: gate
        )
        repository.updateHandleResult = .failure(StubError.feedFailed)
        repository.updateAvatarResult = .failure(StubError.feedFailed)
        await viewModel.loadIfNeeded()

        // Each step is checked on its own: the next reset would clear a message left behind by the one before.
        await endSessionWhileOut(viewModel, repository, gate) { await viewModel.delete(clip) }
        #expect(viewModel.deleteErrorMessage == nil)
        await endSessionWhileOut(viewModel, repository, gate) { _ = await viewModel.updateHandle("@taken") }
        #expect(viewModel.handleErrorMessage == nil)
        await endSessionWhileOut(viewModel, repository, gate) { _ = await viewModel.updateAvatar(rawImageData: Data([0xAA])) }
        #expect(viewModel.avatarErrorMessage == nil)
    }

    @Test func aHandleChangeFinishingAfterTheSessionEndedLeavesTheNextProfileAlone() async {
        let gate = ProfileRequestGate()
        let (viewModel, repository) = makeSUT(result: .success(UserProfile(handle: "@first")), gate: gate)
        repository.updateHandleResult = .success("@renamed")
        await viewModel.loadIfNeeded()

        await endSessionWhileOut(viewModel, repository, gate, thenSignInAs: UserProfile(handle: "@second")) {
            _ = await viewModel.updateHandle("@renamed")
        }

        #expect(viewModel.profile?.handle == "@second")
    }

    @Test func anAvatarFinishingAfterTheSessionEndedLeavesTheNextProfileAlone() async {
        let gate = ProfileRequestGate()
        let (viewModel, repository) = makeSUT(result: .success(UserProfile(handle: "@first")), gate: gate)
        repository.updateAvatarResult = .success(URL(string: "https://cdn.example.com/first.jpg")!)
        await viewModel.loadIfNeeded()

        await endSessionWhileOut(viewModel, repository, gate, thenSignInAs: UserProfile(handle: "@second")) {
            _ = await viewModel.updateAvatar(rawImageData: Data([0xAA]))
        }

        #expect(viewModel.profile?.avatarURL == nil)
    }

    @Test func aDeleteFinishingAfterTheSessionEndedStillTellsTheFeedButLeavesTheNextProfileAlone() async {
        let gate = ProfileRequestGate()
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        let (viewModel, repository) = makeSUT(
            result: .success(UserProfile(handle: "@first", videoCount: 1, videos: [clip])),
            gate: gate
        )
        await viewModel.loadIfNeeded()
        var deleted: [UUID] = []
        viewModel.onClipDeleted = { deleted.append($0) }

        await endSessionWhileOut(viewModel, repository, gate, thenSignInAs: UserProfile(handle: "@second", videoCount: 3)) {
            await viewModel.delete(clip)
        }

        #expect(deleted == [clip.id])
        #expect(viewModel.profile?.videoCount == 3)
    }
}

/// Holds the next profile request until the test lets it finish, so a test can end the session while a request is out.
private actor ProfileRequestGate {
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func holdNextRequest() { holdsNext = true }

    func pass() async {
        guard holdsNext else { return }
        holdsNext = false
        await withCheckedContinuation { held = $0; waiter?.resume(); waiter = nil }
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}

/// Answers like the stub it wraps, but only once the gate lets the request through. The answer is fixed when the request
/// arrives, so a later change to the stub cannot reach a request that is already out.
private struct GatedProfileRepository: UserProfileRepository {
    let base: StubUserProfileRepository
    let gate: ProfileRequestGate

    func fetchProfile() async throws -> UserProfile {
        try await answered { try await base.fetchProfile() }
    }

    func fetchPublicProfile(handle: String) async throws -> PublicUserProfile {
        try await base.fetchPublicProfile(handle: handle)
    }

    func updateHandle(_ handle: String) async throws -> String {
        try await answered { try await base.updateHandle(handle) }
    }

    func updateAvatar(imageData: Data, mimeType: String) async throws -> URL {
        try await answered { try await base.updateAvatar(imageData: imageData, mimeType: mimeType) }
    }

    func deleteClip(id: UUID) async throws {
        try await answered { try await base.deleteClip(id: id) }
    }

    private func answered<T: Sendable>(_ request: () async throws -> T) async throws -> T {
        let answer: Result<T, Error>
        do { answer = .success(try await request()) } catch { answer = .failure(error) }
        await gate.pass()
        return try answer.get()
    }
}
