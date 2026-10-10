//
//  MapLocationRequiredView.swift
//  Marauders
//

import SwiftUI
import UIKit

struct MapLocationRequiredView: View {
    @Bindable var viewModel: MapViewModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "location.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Location required")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Allow location access to open the map and see clip pins near you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if viewModel.isLocationAccessDeniedOrRestricted {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: 320)
                } else {
                    Button("Continue") {
                        viewModel.beginLocationAccessRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("map.locationContinue")
                }
            }
            .padding(24)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("map.locationRequired")
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
            Text("Marauders needs your location to show the map and clip pins.")
        }
        .alert("Location Access Off", isPresented: $viewModel.showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on location for Marauders in Settings to use the Map tab.")
        }
    }
}
