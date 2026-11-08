//
//  PublicProfileView.swift
//  Marauders
//

import SwiftUI

/// Another user's public profile, presented as a sheet when an author handle is tapped. The sheet has a stack of its
/// own, so a follower or following list opens inside it and a row of that list opens the next profile in the same stack.
struct PublicProfileView: View {
    /// Kept for the sheet's whole life: the view is rebuilt whenever the screen under the sheet is, and a new model
    /// would have loaded nothing.
    @State private var viewModel: PublicProfileViewModel
    let navigation: ProfileNavigation
    var onClose: () -> Void

    init(viewModel: PublicProfileViewModel, navigation: ProfileNavigation, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.navigation = navigation
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            PublicProfileScreen(viewModel: viewModel, authViewModel: navigation.authViewModel)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("publicProfile.close")
                    }
                }
                .navigationDestination(for: ProfileRoute.self) { route in
                    ProfileRouteDestination(route: route, navigation: navigation)
                }
        }
        .accessibilityIdentifier("publicProfile.root")
    }
}
