//
//  MapLocationRequiredView.swift
//  Marauders
//

import SwiftUI
import UIKit

struct MapLocationRequiredView: View {
    @Bindable var viewModel: MapViewModel
    /// Lets a viewer who shares stop from here: without location access the map, and its switch, stay closed.
    var friendLocations: FriendLocationsViewModel? = nil

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

                if friendLocations?.sharing == true {
                    VStack(spacing: 8) {
                        Text("You're sharing your last location with mutual followers.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Stop sharing location") {
                            Task { await friendLocations?.setSharing(false) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(friendLocations?.isChangingSharing == true)
                        .accessibilityIdentifier("map.stopSharing")
                    }
                    .padding(.top, 12)
                }
            }
            .padding(24)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("map.locationRequired")
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
