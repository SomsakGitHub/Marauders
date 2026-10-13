//
//  ProfileViewModel.swift
//  Marauders
//

import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var profile: UserProfile?
    private(set) var deleteErrorMessage: String?
    private(set) var handleErrorMessage: String?

    private let loadProfile: LoadUserProfileUseCase
    private let deleteClip: DeleteUserClipUseCase
    private let changeHandle: UpdateUserHandleUseCase

    init(
        loadProfile: LoadUserProfileUseCase,
        deleteClip: DeleteUserClipUseCase,
        updateHandle: UpdateUserHandleUseCase
    ) {
        self.loadProfile = loadProfile
        self.deleteClip = deleteClip
        self.changeHandle = updateHandle
    }

    var clips: [FeedVideo] {
        profile?.videos ?? []
    }

    var handle: String {
        profile?.handle ?? "@marauders"
    }

    func clearDeleteError() {
        deleteErrorMessage = nil
    }

    func clearHandleError() {
        handleErrorMessage = nil
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        state = .loading
        do {
            profile = try await loadProfile.execute()
            state = .loaded
        } catch {
            state = .failed(Self.userFacingMessage(for: error))
            AppLog.warning("profile", "load failed: \(error.localizedDescription)")
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Could not load your profile."
    }

    /// Saves a new @handle; returns true on success.
    @discardableResult
    func updateHandle(_ newHandle: String) async -> Bool {
        do {
            let saved = try await changeHandle.execute(newHandle)
            if let current = profile {
                profile = UserProfile(
                    handle: saved,
                    country: current.country,
                    latitude: current.latitude,
                    longitude: current.longitude,
                    videoCount: current.videoCount,
                    videos: current.videos
                )
            }
            handleErrorMessage = nil
            return true
        } catch {
            handleErrorMessage = Self.userFacingMessage(for: error)
            AppLog.warning("profile", "handle update failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes a clip the user owns, removing it optimistically on success.
    func delete(_ clip: FeedVideo) async {
        deleteErrorMessage = nil
        do {
            try await deleteClip.execute(id: clip.id)
            guard let current = profile else { return }
            profile = UserProfile(
                country: current.country,
                latitude: current.latitude,
                longitude: current.longitude,
                videoCount: max(0, current.videoCount - 1),
                videos: current.videos.filter { $0.id != clip.id }
            )
        } catch {
            deleteErrorMessage = Self.userFacingMessage(for: error)
            AppLog.warning("profile", "delete failed: \(error.localizedDescription)")
        }
    }
}
