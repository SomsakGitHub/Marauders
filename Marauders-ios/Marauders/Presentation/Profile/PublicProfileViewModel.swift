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
    @ObservationIgnored private var loadCount = 0

    private let loadProfile: LoadPublicProfileUseCase
    /// The viewer's follows, shared with the feed. Without it the profile offers no Follow button.
    private let follows: UserFollowsViewModel?

    init(handle: String, loadProfile: LoadPublicProfileUseCase, follows: UserFollowsViewModel? = nil) {
        self.handle = handle
        self.loadProfile = loadProfile
        self.follows = follows
    }

    var clips: [FeedVideo] {
        profile?.videos ?? []
    }

    /// Whether the profile offers Follow: the Worker knows follows, and the profile is not the viewer's own.
    var canFollow: Bool {
        guard follows != nil, let profile, profile.followedByViewer != nil else { return false }
        return profile.isViewer != true
    }

    var isFollowing: Bool {
        guard let profile else { return false }
        let loaded = profile.followedByViewer ?? false
        return follows?.isFollowing(profile.handle, fallback: loaded) ?? loaded
    }

    /// Nil from a Worker that predates follows.
    var followerCount: Int? {
        guard let profile else { return nil }
        return follows?.followerCount(of: profile.handle, fallback: profile.followerCount) ?? profile.followerCount
    }

    /// Follows the account, or stops following it. The caller makes sure the viewer is signed in.
    func toggleFollow() {
        guard canFollow, let profile else { return }
        follows?.toggle(profile.handle, fallback: profile.followedByViewer ?? false)
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    /// Loads overlap (pull to refresh, Retry, the reload after a sign-in or sign-out); only the newest one's answer counts.
    func reload() async {
        loadCount += 1
        let load = loadCount
        state = .loading
        let stamp = follows?.stamp()
        do {
            let loaded = try await loadProfile.execute(handle: handle)
            guard load == loadCount else { return }
            profile = loaded
            // What the Worker says now is the newest word on this account, for the feed's rail too.
            if let stamp, loaded.isViewer != true, let following = loaded.followedByViewer, let count = loaded.followerCount {
                follows?.record(loaded.handle, following: following, followerCount: count, loadedAt: stamp)
            }
            state = .loaded
        } catch {
            guard load == loadCount else { return }
            state = .failed(Self.userFacingMessage(for: error))
            AppLog.warning("profile", "public load failed: \(error.localizedDescription)")
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Couldn't load this profile"
    }
}
