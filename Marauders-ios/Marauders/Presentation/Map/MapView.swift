//
//  MapView.swift
//  Marauders
//

import MapKit
import SwiftUI
import UIKit

struct MapView: View {
    @Bindable var viewModel: MapViewModel
    var onSignOut: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var position = MapCameraPosition.region(Self.defaultRegion)

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                if viewModel.canShowUserOnMap {
                    UserAnnotation()
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.currentLocationButtonTapped()
                    } label: {
                        Image(systemName: "location.fill")
                    }
                    .accessibilityLabel("Current Location")
                    .accessibilityIdentifier("map.currentLocation")
                }
                if let onSignOut {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sign Out", action: onSignOut)
                    }
                }
            }
        }
        .accessibilityIdentifier("map.root")
        .onChange(of: viewModel.cameraCenterGeneration) { _, _ in
            guard let region = viewModel.regionForCameraCenter() else { return }
            position = .region(region)
        }
        .confirmationDialog(
            "Use your location?",
            isPresented: $viewModel.showLocationPrePrompt,
            titleVisibility: .visible
        ) {
            Button("Continue") {
                viewModel.confirmLocationPermissionRequest()
            }
            Button("Not Now", role: .cancel) {
                viewModel.cancelLocationPermissionRequest()
            }
        } message: {
            Text("We use your location to show your position on the map.")
        }
        .alert("Location Access Off", isPresented: $viewModel.showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on location for Marauders in Settings to center the map on you.")
        }
    }

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    )
}

#Preview {
    MapView(viewModel: MapViewModel(), onSignOut: nil)
}
