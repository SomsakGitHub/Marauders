//
//  MapTabView.swift
//  Marauders
//

import SwiftUI

struct MapTabView: View {
    @Bindable var authViewModel: AuthViewModel
    @Bindable var feedViewModel: VideoFeedViewModel
    let onOpenClipInFeed: (UUID) async -> Void

    @State private var mapViewModel: MapViewModel

    init(
        authViewModel: AuthViewModel,
        feedViewModel: VideoFeedViewModel,
        reportUserLocation: ReportUserLocationUseCase? = nil,
        onOpenClipInFeed: @escaping (UUID) async -> Void
    ) {
        self.authViewModel = authViewModel
        self.feedViewModel = feedViewModel
        self.onOpenClipInFeed = onOpenClipInFeed
        _mapViewModel = State(initialValue: MapViewModel(reportUserLocation: reportUserLocation))
    }

    var body: some View {
        Group {
            if authViewModel.isCheckingCredential {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authViewModel.isSignedIn {
                if mapViewModel.canAccessMap {
                    MapView(
                        viewModel: mapViewModel,
                        feedViewModel: feedViewModel,
                        onSignOut: { authViewModel.signOut() },
                        onOpenClipInFeed: { videoID in
                            Task { await onOpenClipInFeed(videoID) }
                        }
                    )
                    .task {
                        await feedViewModel.syncHeadWithServer()
                    }
                } else {
                    MapLocationRequiredView(viewModel: mapViewModel)
                }
            } else {
                MapSignInRequiredView(authViewModel: authViewModel)
            }
        }
        .task {
            await authViewModel.restoreSession()
        }
        .task(id: authViewModel.isSignedIn) {
            guard authViewModel.isSignedIn else { return }
            await feedViewModel.loadIfNeeded()
        }
        .onAppear {
            mapViewModel.syncAuthorizationStatusFromSystem()
        }
        .onChange(of: mapViewModel.canAccessMap) { _, canAccess in
            guard canAccess else { return }
            mapViewModel.onMapTabBecameActive()
        }
    }
}

#Preview {
    let container = AppDependencyContainer()
    MapTabView(
        authViewModel: container.authViewModel,
        feedViewModel: container.feedViewModel,
        reportUserLocation: container.reportUserLocation,
        onOpenClipInFeed: { _ in }
    )
}
