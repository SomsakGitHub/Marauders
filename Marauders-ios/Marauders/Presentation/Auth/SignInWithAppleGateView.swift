//
//  SignInWithAppleGateView.swift
//  Marauders
//

import AuthenticationServices
import SwiftUI

struct SignInWithAppleGateView: View {
    @Bindable var authViewModel: AuthViewModel

    let navigationTitle: String
    let systemImage: String
    let title: String
    let subtitle: String
    let accessibilityIdentifier: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    authViewModel.handleAuthorization(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: 320, minHeight: 48, maxHeight: 48)
                .padding(.top, 8)

                if let errorMessage = authViewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
