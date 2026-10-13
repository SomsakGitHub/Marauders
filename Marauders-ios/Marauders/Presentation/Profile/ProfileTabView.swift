//
//  ProfileTabView.swift
//  Marauders
//

import SwiftUI

struct ProfileTabView: View {
    @Bindable var authViewModel: AuthViewModel
    @Bindable var profileViewModel: ProfileViewModel

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
                SignInWithAppleGateView(
                    authViewModel: authViewModel,
                    navigationTitle: "Profile",
                    systemImage: "person.crop.circle.fill",
                    title: "Sign in to view your profile",
                    subtitle: "Your clips and account require Sign in with Apple.",
                    accessibilityIdentifier: "profile.signInRequired"
                )
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
