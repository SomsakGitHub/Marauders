//
//  ProfileRoute.swift
//  Marauders
//

import SwiftUI

/// Where a push inside a profile's `NavigationStack` goes: a follower or following list, or another account's profile.
enum ProfileRoute: Hashable {
    case followList(handle: String, kind: FollowListKind)
    case profile(handle: String)
}

/// What the screens that push profiles and lists need. `ContentView` builds it once and hands it down, so the Profile
/// tab and the profile sheet push the same screens against the same follows and the same session.
struct ProfileNavigation {
    let authViewModel: AuthViewModel
    let followsViewModel: UserFollowsViewModel
    let makePublicProfileViewModel: (String) -> PublicProfileViewModel
    let makeFollowListViewModel: (String, FollowListKind) -> FollowListViewModel
}

/// The screen a `ProfileRoute` opens. Every profile stack registers it with `navigationDestination(for:)`, so a push
/// from any depth resolves.
struct ProfileRouteDestination: View {
    let route: ProfileRoute
    let navigation: ProfileNavigation

    var body: some View {
        switch route {
        case .profile(let handle):
            PublicProfileDestination(handle: handle, navigation: navigation)
        case .followList(let handle, let kind):
            FollowListView(handle: handle, kind: kind, navigation: navigation)
        }
    }
}

/// A profile pushed from a list. A destination closure runs again whenever the stack's content does, so the view model
/// is kept in `@State` here: a new one would load nothing and lose what the viewer was looking at.
private struct PublicProfileDestination: View {
    @State private var viewModel: PublicProfileViewModel
    private let authViewModel: AuthViewModel

    init(handle: String, navigation: ProfileNavigation) {
        _viewModel = State(initialValue: navigation.makePublicProfileViewModel(handle))
        authViewModel = navigation.authViewModel
    }

    var body: some View {
        PublicProfileScreen(viewModel: viewModel, authViewModel: authViewModel)
    }
}
