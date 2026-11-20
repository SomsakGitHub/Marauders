//
//  AppDependencyContainerWiringTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// What the composition root hands to the screens whose real collaborators are Data types. Presentation cannot name
/// those types, so a screen left unwired would quietly do nothing instead of failing to compile.
@MainActor
struct AppDependencyContainerWiringTests {
    @Test func theUploadScreenChecksTheAudioOfAClipItPrepares() async throws {
        let clip = try TestFixtureFiles.temporaryToneFile()
        defer { try? FileManager.default.removeItem(at: clip) }
        let container = AppDependencyContainer(videoExporter: StubVideoExporter(result: .success(clip)))
        await container.uploadViewModel.prepare(sourceURL: clip)
        // Without the real inspector the assessment would stay `.unknown`.
        #expect(container.uploadViewModel.audioAssessment?.signal == .detected)
    }

    @Test func theLanguageModelsScreenReadsTheRealDetectionModel() async throws {
        let viewModel = AppDependencyContainer().languageModelsViewModel
        await viewModel.refresh()
        let detection = try #require(viewModel.detectionModels.first)
        // A manager that supports nothing answers `.unsupported`; the real one answers for the model store.
        let status = viewModel.status(of: detection)
        #expect(status == .installed || status == .notInstalled)
    }

    @Test func thePickerChecksWhichLanguagesThisIPhoneCanServe() {
        #expect(AppDependencyContainer().listeningLanguageAvailability is SystemListeningLanguageAvailability)
    }

    @Test func theFeedPlaysFromTheSessionCacheItStartsFrom() {
        // The feed screen builds its player from the media cache its view model carries. Without the shared session
        // cache there, clips the cache already holds would stream again.
        let cache = AppDependencyContainer().feedViewModel.mediaCache
        #expect((cache as? SessionFeedStartupCache) === FeedStartupCache.shared)
    }

    @Test func theAuthViewModelIsGivenBothUploadHooks() {
        // Presentation cannot name the uploader, so a view model left without its hooks would sign out and sign in
        // without a word to it: the account's clip would stay on the phone, and another account's upload would stay
        // ready to be sent.
        let authViewModel = AppDependencyContainer().authViewModel
        #expect(authViewModel.discardUploadOnSignOut != nil)
        #expect(authViewModel.checkUploadOnSignIn != nil)
    }

    // MARK: - The stores the screens share

    /// A container whose language stores keep their choices in a suite of the test's own, never in the defaults the
    /// whole test run shares.
    private func makeContainerWithOwnDefaults() -> AppDependencyContainer {
        AppDependencyContainer(viewerDefaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
    }

    @Test func theListeningPickerAndTheStoreAreOneChoice() {
        let container = makeContainerWithOwnDefaults()
        #expect(container.listeningLanguagePicker.choose(.spanish))
        #expect(container.listeningLanguageStore.explicit == .spanish)
    }

    @Test func theLanguageModelsScreenFollowsTheContainersListeningChoice() {
        let container = makeContainerWithOwnDefaults()
        container.listeningLanguageStore.choose(.thai)
        #expect(
            container.languageModelsViewModel.translationModels.map(\.id)
                == LanguageModel.translationModels(for: [.thai]).map(\.id))
    }

    @Test func theListeningStoreReadsWhatTheContainersMemoRemembers() {
        let container = makeContainerWithOwnDefaults()
        let clip = FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!)
        #expect(container.listeningLanguageStore.declaredCode(for: clip) == nil)
        container.detectedLanguageMemo.remember("es", for: clip.id)
        #expect(container.listeningLanguageStore.declaredCode(for: clip) == "es")
    }

    @Test func aDubbingViewModelTheContainerMakesSharesTheContainersStores() {
        let container = makeContainerWithOwnDefaults()
        let model = container.makeDubbingViewModel()
        #expect(model.memo === container.detectedLanguageMemo)
        #expect(model.reports === container.dubbedAudioReportMemory)
        #expect(model.consent === container.languageDetectionConsent)
    }

    @Test func decliningTheDetectionModelIsRememberedByTheContainer() {
        let container = makeContainerWithOwnDefaults()
        #expect(!container.languageDetectionConsent.declined)
        container.makeDubbingViewModel().declineDetectionModel()
        #expect(container.languageDetectionConsent.declined)
    }

    @Test func nothingOneContainerRemembersReachesAnother() {
        let first = makeContainerWithOwnDefaults()
        let second = makeContainerWithOwnDefaults()
        first.languageDetectionConsent.decline()
        first.listeningLanguageStore.choose(.thai)
        #expect(!second.languageDetectionConsent.declined)
        #expect(second.listeningLanguageStore.explicit == nil)
    }

    // MARK: - The uploader's rejections

    /// A container over stores of the test's own and over `uploader`, never the Keychain or the process-wide uploader
    /// the whole test run shares.
    private func makeContainer(
        storage: SignOutSessionStorage = SignOutSessionStorage(),
        uploader: BackgroundClipUploader
    ) -> AppDependencyContainer {
        AppDependencyContainer(
            sessionStores: (session: storage, accessToken: storage, refreshToken: MemoryRefreshTokenStore()),
            clipUploader: uploader)
    }

    @Test func theUploadersRejectionsReachTheViewerOfTheContainerThatConnectedThem() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let token = UploaderKit.validToken()
        let storage = SignOutSessionStorage(userID: "user-1", accessToken: token)
        let kept = makeContainer(storage: storage, uploader: kit.uploader)
        await kept.connectUploaderRejections()

        // SwiftUI builds a container for every new root view and keeps only the first; the others are dropped.
        do { _ = makeContainer(uploader: kit.uploader) }
        await UploaderKit.settle()

        let report = try #require(await kit.uploader.rejectionReporter)
        await report(token)

        #expect(storage.accessToken == nil, "the viewer whose token the Worker rejected is signed out")
        #expect(storage.userID == nil)
        #expect(!kept.authViewModel.isSignedIn)
    }

    @Test func buildingAContainerConnectsNothingToTheUploader() async {
        let kit = UploaderKit()
        defer { kit.cleanUp() }

        _ = makeContainer(uploader: kit.uploader)
        await UploaderKit.settle()

        #expect(await kit.uploader.rejectionReporter == nil)
    }

    // MARK: - Deleting the account

    /// A container over a session of the test's own (a test user of the Simulator's debug sign in, who needs no Apple
    /// answer to be signed in), the test's own uploader and a repository that answers as the test says.
    private func makeSignedInContainer(
        deleting repository: AccountDeletionRepository, kit: UploaderKit
    ) async -> (container: AppDependencyContainer, storage: SignOutSessionStorage) {
        let storage = SignOutSessionStorage(userID: "dev:wiring", accessToken: UploaderKit.validToken())
        let container = AppDependencyContainer(
            accountDeletionRepository: repository,
            sessionStores: (session: storage, accessToken: storage, refreshToken: MemoryRefreshTokenStore()),
            clipUploader: kit.uploader)
        await container.authViewModel.restoreSession()
        return (container, storage)
    }

    @Test func finishingADeletionSignsTheContainersViewerOut() async {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let repository = StubAccountDeletionRepository()
        let (container, storage) = await makeSignedInContainer(deleting: repository, kit: kit)
        #expect(container.authViewModel.isSignedIn, "the viewer is signed in before the deletion")

        await container.accountDeletionViewModel.delete(authorizationCode: "code-1")

        #expect(repository.codes == ["code-1"])
        #expect(container.accountDeletionViewModel.phase == .deleted)
        // Presentation cannot name the container's stores: a view model left without its callback would show the
        // confirmation of a deleted account to a viewer who is still signed in to it.
        #expect(storage.accessToken == nil)
        #expect(storage.userID == nil)
        #expect(!container.authViewModel.isSignedIn)
    }

    @Test func aFailedDeletionKeepsTheSession() async {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        let repository = StubAccountDeletionRepository()
        let reason = AccountDeletionError.couldNotFinish
        repository.failure = reason
        let (container, storage) = await makeSignedInContainer(deleting: repository, kit: kit)

        await container.accountDeletionViewModel.delete(authorizationCode: "code-1")

        #expect(container.accountDeletionViewModel.phase == .failed(reason.errorDescription ?? ""))
        #expect(storage.accessToken != nil)
        #expect(storage.userID == "dev:wiring")
        #expect(container.authViewModel.isSignedIn)
    }

    @Test func theDeletionClearsThePersonalFeedCache() async throws {
        let kit = UploaderKit()
        defer { kit.cleanUp() }
        // The cache the container's feed starts from lives in the Caches folder of this app, so a deletion that did not
        // reach it would leave on the phone what the deleted account saw. A marker stands for one of its clips.
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PersonalFeedStartup-v2", directoryHint: .isDirectory)
        let marker = folder.appending(path: "marker-\(UUID().uuidString).mp4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        let (container, _) = await makeSignedInContainer(deleting: StubAccountDeletionRepository(), kit: kit)
        #expect(FileManager.default.fileExists(atPath: marker.path), "the marker is there before the deletion")

        await container.accountDeletionViewModel.delete(authorizationCode: "code-1")

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

/// A deletion that succeeds, or fails the way the test says; it remembers the codes it was asked with.
private final class StubAccountDeletionRepository: AccountDeletionRepository, @unchecked Sendable {
    private(set) var codes: [String?] = []
    var failure: Error?

    func deleteAccount(authorizationCode: String?) async throws {
        codes.append(authorizationCode)
        if let failure { throw failure }
    }
}
