//
//  PublicProfileView.swift
//  Marauders
//

import SwiftUI

/// Another user's public profile, presented when an author handle is tapped.
struct PublicProfileView: View {
    /// Kept for the sheet's whole life: the view is rebuilt whenever the screen under the sheet is, and a new model
    /// would have loaded nothing.
    @State private var viewModel: PublicProfileViewModel
    let authViewModel: AuthViewModel
    var onClose: () -> Void

    @State private var selectedClip: FeedVideo?
    /// A guest's Follow opens sign-in over the profile, so they are still on it once signed in.
    @State private var showingSignIn = false

    init(viewModel: PublicProfileViewModel, authViewModel: AuthViewModel, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.authViewModel = authViewModel
        self.onClose = onClose
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    errorState(message)
                case .loaded:
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("publicProfile.close")
                }
            }
        }
        .accessibilityIdentifier("publicProfile.root")
        .task {
            await viewModel.loadIfNeeded()
        }
        .fullScreenCover(item: $selectedClip) { clip in
            ClipPlayerView(
                clip: clip,
                onClose: { selectedClip = nil }
            )
        }
        .sheet(isPresented: $showingSignIn) {
            SignInSheet(authViewModel: authViewModel, onClose: { showingSignIn = false })
        }
        .onChange(of: authViewModel.isSignedIn) { _, signedIn in
            if signedIn { showingSignIn = false }
            // Whether the viewer follows this account, or is it, belongs to the session that just began or ended.
            Task { await viewModel.reload() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if viewModel.clips.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
        .refreshable {
            await viewModel.reload()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(
                url: viewModel.profile?.avatarURL,
                handle: viewModel.profile?.handle ?? viewModel.handle,
                size: 76
            )

            Text(viewModel.profile?.handle ?? viewModel.handle)
                .font(.headline)
                .accessibilityIdentifier("publicProfile.handle")

            if let country = viewModel.profile?.country, !country.isEmpty {
                Text("\(Country.flagEmoji(for: country)) \(CountryCatalog.name(for: country))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("publicProfile.country")
            }

            stats

            if viewModel.canFollow {
                followButton
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var stats: some View {
        HStack(spacing: 24) {
            if let following = viewModel.profile?.followingCount {
                ProfileStat(count: following, label: "Following")
                    .accessibilityIdentifier("publicProfile.followingCount")
            }
            if let followers = viewModel.followerCount {
                ProfileStat(count: followers, label: "Followers")
                    .accessibilityIdentifier("publicProfile.followerCount")
            }
            ProfileStat(count: viewModel.profile?.videoCount ?? 0, label: "Clips")
                .accessibilityIdentifier("publicProfile.clipCount")
        }
    }

    /// Red Follow as on TikTok; once followed it turns grey, and tapping it again stops following.
    private var followButton: some View {
        let following = viewModel.isFollowing
        return Button {
            guard authViewModel.isSignedIn else { showingSignIn = true; return }
            viewModel.toggleFollow()
        } label: {
            (following ? Text("Following") : Text("Follow"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(following ? Color.primary : Color.white)
                .frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .tint(following ? Color(.systemGray5) : Color.likeRed)
        .animation(.snappy, value: following)
        .accessibilityIdentifier("publicProfile.follow")
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(viewModel.clips) { clip in
                Button {
                    selectedClip = clip
                } label: {
                    ProfileClipThumbnail(clip: clip)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("publicProfile.clip")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No clips yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("publicProfile.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
