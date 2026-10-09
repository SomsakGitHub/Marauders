//
//  MapView.swift
//  Marauders
//

import MapKit
import SwiftUI

struct MapView: View {
    var onSignOut: (() -> Void)?

    @State private var position = MapCameraPosition.region(Self.defaultRegion)

    var body: some View {
        NavigationStack {
            Map(position: $position)
                .mapStyle(.standard(elevation: .realistic))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onSignOut {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Sign Out", action: onSignOut)
                        }
                    }
                }
        }
        .accessibilityIdentifier("map.root")
    }

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    )
}

#Preview {
    MapView()
}
