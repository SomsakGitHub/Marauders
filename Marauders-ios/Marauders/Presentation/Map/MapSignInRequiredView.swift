//
//  MapSignInRequiredView.swift
//  Marauders
//

import SwiftUI

struct MapSignInRequiredView: View {
    @Bindable var authViewModel: AuthViewModel

    var body: some View {
        SignInWithAppleGateView(
            authViewModel: authViewModel,
            navigationTitle: "Map",
            systemImage: "map.fill",
            title: "Sign in to use the map",
            subtitle: "Map features require Sign in with Apple.",
            accessibilityIdentifier: "map.signInRequired"
        )
    }
}

#Preview {
    MapSignInRequiredView(authViewModel: AuthViewModel())
}
