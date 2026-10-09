//
//  MapSignInRequiredView.swift
//  Marauders
//

import AuthenticationServices
import SwiftUI

struct MapSignInRequiredView: View {
    @Bindable var authViewModel: AuthViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "map.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Sign in to use the map")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Map features require Sign in with Apple.")
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
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("map.signInRequired")
    }
}

#Preview {
    MapSignInRequiredView(authViewModel: AuthViewModel(sessionStore: PreviewAuthSessionStore()))
}

private final class PreviewAuthSessionStore: AuthSessionStore, @unchecked Sendable {
    func loadUserID() -> String? { nil }
    func saveUserID(_ userID: String) throws {}
    func clear() throws {}
}
