//
//  SignInSheet.swift
//  Marauders
//

import SwiftUI

/// The sign-in screen the app's "sign in to …" prompts open: Sign in with Apple, with a button to back out.
struct SignInSheet: View {
    @Bindable var authViewModel: AuthViewModel
    var onClose: () -> Void

    var body: some View {
        SignInWithAppleGateView(
            authViewModel: authViewModel,
            navigationTitle: "Sign in",
            systemImage: "person.crop.circle.fill",
            title: "Welcome to Marauders",
            subtitle: "Sign in with Apple to continue.",
            accessibilityIdentifier: "auth.signIn"
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title2).padding()
            }
            .accessibilityLabel("Close sign in")
            .accessibilityIdentifier("auth.closeSignIn")
        }
    }
}
