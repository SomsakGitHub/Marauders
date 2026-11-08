//
//  FollowListView.swift
//  Marauders
//

import SwiftUI

/// A profile's Followers and Following in one screen, with a switch between the two. It opens on the list whose count
/// was tapped, builds a view model for each list with the screen, and loads a list the first time its tab is shown.
struct FollowListView: View {
    let handle: String
    let navigation: ProfileNavigation

    @State private var selectedKind: FollowListKind
    @State private var models: [FollowListKind: FollowListViewModel]
    @State private var showingSignIn = false
    /// The session the lists in `models` were loaded under. A list belongs to the viewer who asked for it.
    @State private var sessionOfLists: Bool?

    private struct LoadKey: Equatable {
        let kind: FollowListKind
        let isSignedIn: Bool
    }

    init(handle: String, kind: FollowListKind, navigation: ProfileNavigation) {
        self.handle = handle
        self.navigation = navigation
        _selectedKind = State(initialValue: kind)
        _models = State(initialValue: Dictionary(uniqueKeysWithValues: FollowListKind.allCases.map {
            ($0, navigation.makeFollowListViewModel(handle, $0))
        }))
    }

    private var isSignedIn: Bool { navigation.authViewModel.isSignedIn }

    var body: some View {
        VStack(spacing: 0) {
            Picker("List", selection: $selectedKind) {
                Text("Followers").tag(FollowListKind.followers)
                Text("Following").tag(FollowListKind.following)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("followList.tabs")

            if let model = models[selectedKind] {
                FollowListPane(
                    model: model,
                    isSignedIn: isSignedIn,
                    followsViewModel: navigation.followsViewModel,
                    onSignIn: { showingSignIn = true }
                )
                // A new list, not the other tab's rows with a new title.
                .id(selectedKind)
            }
        }
        .navigationTitle(handle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("followList.root")
        .task(id: LoadKey(kind: selectedKind, isSignedIn: isSignedIn)) {
            await showSelectedList()
        }
        .onChange(of: isSignedIn) { _, signedIn in
            if signedIn { showingSignIn = false }
        }
        .sheet(isPresented: $showingSignIn) {
            SignInSheet(authViewModel: navigation.authViewModel, onClose: { showingSignIn = false })
        }
    }

    /// Runs when the tab or the session changes. The reset is done here, not in a separate `onChange`, so it always
    /// happens before the load it makes room for.
    private func showSelectedList() async {
        if sessionOfLists != isSignedIn {
            for model in models.values { model.resetForSessionChange() }
            sessionOfLists = isSignedIn
        }
        guard isSignedIn, let model = models[selectedKind] else { return }
        await model.loadIfNeeded()
    }
}

/// One list: its rows, or why there are none.
private struct FollowListPane: View {
    let model: FollowListViewModel
    let isSignedIn: Bool
    let followsViewModel: UserFollowsViewModel
    let onSignIn: () -> Void

    var body: some View {
        Group {
            if !isSignedIn || model.needsSignIn {
                signInPrompt
            } else {
                switch model.state {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("followList.loading")
                case .failed(let message):
                    errorState(message)
                case .loaded:
                    if model.entries.isEmpty {
                        emptyState
                    } else {
                        rows
                    }
                }
            }
        }
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.entries) { entry in
                    row(entry)
                        .onAppear {
                            Task { await model.loadMoreIfNeeded(currentItem: entry) }
                        }
                }
                footer
            }
        }
        .refreshable {
            await model.reload()
        }
    }

    private func row(_ entry: FollowListEntry) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: ProfileRoute.profile(handle: entry.handle)) {
                HStack(spacing: 12) {
                    AvatarView(url: entry.avatarURL, handle: entry.handle, size: 44)
                    Text(entry.handle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("followList.row")

            if !entry.isViewer {
                followButton(entry)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Red Follow, grey Following, as on a profile. It reads and writes the viewer's shared follows, so the row, the
    /// feed's "+" and every profile agree.
    private func followButton(_ entry: FollowListEntry) -> some View {
        let following = followsViewModel.isFollowing(entry.handle, fallback: entry.followedByViewer)
        return Button {
            followsViewModel.toggle(entry.handle, fallback: entry.followedByViewer)
        } label: {
            (following ? Text("Following") : Text("Follow"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(following ? Color.primary : Color.white)
                .frame(minWidth: 84)
        }
        .buttonStyle(.borderedProminent)
        .tint(following ? Color(.systemGray5) : Color.likeRed)
        .animation(.snappy, value: following)
        .accessibilityIdentifier("followList.follow")
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoadingMore {
            ProgressView()
                .padding(.vertical, 16)
        } else if model.loadMoreFailed {
            VStack(spacing: 8) {
                Text("Couldn't load more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await model.retryLoadMore() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("followList.retryMore")
            }
            .padding(.vertical, 16)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(model.kind == .followers ? "No followers yet" : "Not following anyone yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("followList.empty")
        }
        .refreshable {
            await model.reload()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Task { await model.reload() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("followList.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signInPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Sign in to see this list")
                .font(.subheadline)
            Button("Sign in", action: onSignIn)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("followList.signIn")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
