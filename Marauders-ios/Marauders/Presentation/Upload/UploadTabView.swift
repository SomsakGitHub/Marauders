//
//  UploadTabView.swift
//  Marauders
//

import SwiftUI

struct UploadTabView: View {
    @Bindable var authViewModel: AuthViewModel
    @Bindable var uploadViewModel: UploadVideoViewModel

    var body: some View {
        Group {
            if authViewModel.isCheckingCredential {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authViewModel.isSignedIn {
                UploadVideoView(viewModel: uploadViewModel)
            } else {
                SignInWithAppleGateView(
                    authViewModel: authViewModel,
                    navigationTitle: "Upload",
                    systemImage: "plus.circle.fill",
                    title: "Sign in to upload",
                    subtitle: "Uploading clips requires Sign in with Apple.",
                    accessibilityIdentifier: "upload.signInRequired"
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
    UploadTabView(
        authViewModel: container.authViewModel,
        uploadViewModel: container.uploadViewModel
    )
}
