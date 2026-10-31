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
    private(set) var avatarErrorMessage: String?
    private(set) var isUpdatingAvatar = false

    /// Bumped whenever the session ends, so a request that was still out then can tell its answer is stale.
    private var sessionGeneration = 0

    /// Called with (oldHandle, newHandle) after a @handle change succeeds, so other tabs can update.
    var onHandleChanged: ((_ oldHandle: String, _ newHandle: String) -> Void)?
    /// Called with (newAvatarURL, handle) after a successful avatar change.
    var onAvatarChanged: ((_ avatarURL: URL, _ handle: String) -> Void)?
    /// Called with the clip's ID after the server deleted it, so the feed and the map stop showing it.
    var onClipDeleted: ((_ clipID: UUID) -> Void)?

    private let loadProfile: LoadUserProfileUseCase
    private let deleteClip: DeleteUserClipUseCase
    private let changeHandle: UpdateUserHandleUseCase
    private let changeAvatar: UpdateAvatarUseCase

    init(
        loadProfile: LoadUserProfileUseCase,
        deleteClip: DeleteUserClipUseCase,
        updateHandle: UpdateUserHandleUseCase,
        updateAvatar: UpdateAvatarUseCase
    ) {
        self.loadProfile = loadProfile
        self.deleteClip = deleteClip
        self.changeHandle = updateHandle
        self.changeAvatar = updateAvatar
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

    func clearAvatarError() {
        avatarErrorMessage = nil
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        let generation = sessionGeneration
        state = .loading
        do {
            let loaded = try await loadProfile.execute()
            guard generation == sessionGeneration else { return }
            profile = loaded
            state = .loaded
        } catch {
            guard generation == sessionGeneration else { return }
            state = .failed(Self.userFacingMessage(for: error))
            AppLog.warning("profile", "load failed: \(error.localizedDescription)")
        }
    }

    /// Forgets what the ended session loaded, so the next sign-in fetches its own profile, and drops the answer of
    /// any request that was still out.
    func resetForSessionChange() {
        sessionGeneration += 1
        profile = nil
        state = .idle
        deleteErrorMessage = nil
        handleErrorMessage = nil
        avatarErrorMessage = nil
        isUpdatingAvatar = false
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
        let generation = sessionGeneration
        let previousHandle = profile?.handle
        do {
            let saved = try await changeHandle.execute(newHandle)
            guard generation == sessionGeneration else { return true }
            if let current = profile {
                profile = UserProfile(
                    handle: saved,
                    country: current.country,
                    avatarURL: current.avatarURL,
                    latitude: current.latitude,
                    longitude: current.longitude,
                    videoCount: current.videoCount,
                    videos: current.videos
                )
            }
            handleErrorMessage = nil
            onHandleChanged?(previousHandle ?? "", saved)
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            handleErrorMessage = Self.userFacingMessage(for: error)
            AppLog.warning("profile", "handle update failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Uploads a new avatar from raw picked image data; returns true on success.
    @discardableResult
    func updateAvatar(rawImageData: Data) async -> Bool {
        guard !isUpdatingAvatar else { return false }
        let generation = sessionGeneration
        isUpdatingAvatar = true
        avatarErrorMessage = nil
        defer { isUpdatingAvatar = false }

        do {
            let url = try await changeAvatar.execute(rawImageData: rawImageData)
            guard generation == sessionGeneration else { return true }
            if let current = profile {
                profile = UserProfile(
                    handle: current.handle,
                    country: current.country,
                    avatarURL: url,
                    latitude: current.latitude,
                    longitude: current.longitude,
                    videoCount: current.videoCount,
                    videos: current.videos
                )
            }
            onAvatarChanged?(url, profile?.handle ?? "")
            AppLog.info("profile", "avatar updated")
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            avatarErrorMessage = Self.userFacingMessage(for: error)
            AppLog.warning("profile", "avatar update failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes a clip the user owns, removing it optimistically on success.
    func delete(_ clip: FeedVideo) async {
        let generation = sessionGeneration
        deleteErrorMessage = nil
        do {
            try await deleteClip.execute(id: clip.id)
            onClipDeleted?(clip.id)
            guard generation == sessionGeneration, let current = profile else { return }
            profile = UserProfile(
                handle: current.handle,
                country: current.country,
                avatarURL: current.avatarURL,
                latitude: current.latitude,
                longitude: current.longitude,
                videoCount: max(0, current.videoCount - 1),
                videos: current.videos.filter { $0.id != clip.id }
            )
        } catch {
            guard generation == sessionGeneration else { return }
            deleteErrorMessage = Self.userFacingMessage(for: error)
            AppLog.warning("profile", "delete failed: \(error.localizedDescription)")
        }
    }
}
