//
//  MapTabView.swift
//  Marauders
//

import SwiftUI

struct MapTabView: View {
    @Bindable var authViewModel: AuthViewModel
    @State private var mapViewModel = MapViewModel()

    var body: some View {
        Group {
            if authViewModel.isCheckingCredential {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authViewModel.isSignedIn {
                MapView(
                    viewModel: mapViewModel,
                    onSignOut: { authViewModel.signOut() }
                )
            } else {
                MapSignInRequiredView(authViewModel: authViewModel)
            }
        }
        .task {
            await authViewModel.restoreSession()
        }
    }
}

#Preview {
    MapTabView(authViewModel: AuthViewModel(sessionStore: PreviewAuthSessionStore()))
}

private final class PreviewAuthSessionStore: AuthSessionStore, @unchecked Sendable {
    func loadUserID() -> String? { nil }
    func saveUserID(_ userID: String) throws {}
    func clear() throws {}
}
