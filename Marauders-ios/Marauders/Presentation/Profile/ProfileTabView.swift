//
//  ProfileTabView.swift
//  Marauders
//

import SwiftUI

struct ProfileTabView: View {
    @Bindable var authViewModel: AuthViewModel
    @Bindable var profileViewModel: ProfileViewModel

    var onSignIn: () -> Void = {}

    var body: some View {
        Group {
            if authViewModel.isCheckingCredential {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authViewModel.isSignedIn {
                ProfileView(
                    viewModel: profileViewModel,
                    onSignOut: { authViewModel.signOut() }
                )
            } else {
                SignInRequiredView(onSignIn: onSignIn)
                    .accessibilityIdentifier("profile.signInRequired")
            }
        }
        .task {
            await authViewModel.restoreSession()
        }
    }
}

#Preview {
    let container = AppDependencyContainer()
    ProfileTabView(
        authViewModel: container.authViewModel,
        profileViewModel: container.profileViewModel
    )
}
