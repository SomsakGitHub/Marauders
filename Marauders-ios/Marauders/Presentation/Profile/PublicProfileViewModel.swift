//
//  PublicProfileViewModel.swift
//  Marauders
//

import Foundation
import Observation

@MainActor
@Observable
final class PublicProfileViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let handle: String
    private(set) var state: LoadState = .idle
    private(set) var profile: PublicUserProfile?

    private let loadProfile: LoadPublicProfileUseCase

    init(handle: String, loadProfile: LoadPublicProfileUseCase) {
        self.handle = handle
        self.loadProfile = loadProfile
    }

    var clips: [FeedVideo] {
        profile?.videos ?? []
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        state = .loading
        do {
            profile = try await loadProfile.execute(handle: handle)
            state = .loaded
        } catch {
            state = .failed(Self.userFacingMessage(for: error))
            AppLog.warning("profile", "public load failed: \(error.localizedDescription)")
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Couldn't load this profile"
    }
}
