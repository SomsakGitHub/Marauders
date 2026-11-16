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
}
