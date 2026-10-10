//
//  MapView.swift
//  Marauders
//

import MapKit
import SwiftUI
import UIKit

struct MapView: View {
    @Bindable var viewModel: MapViewModel
    @Bindable var feedViewModel: VideoFeedViewModel
    var onSignOut: (() -> Void)?
    var onOpenClipInFeed: (UUID) -> Void

    @Environment(\.openURL) private var openURL
    @State private var position = MapCameraPosition.region(Self.defaultRegion)
    @State private var selectedClip: FeedVideo?
    @State private var isNearMeActive = false

    private let nearMeRadiusMeters = MapClipProximity.defaultNearMeRadiusMeters

    private var clipsOnMap: [FeedVideo] {
        let all = feedViewModel.videosWithMapCoordinates
        guard isNearMeActive, let user = viewModel.userCoordinate else { return all }
        return MapClipProximity.clips(within: nearMeRadiusMeters, of: user, from: all)
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                if viewModel.canShowUserOnMap {
                    UserAnnotation()
                }
                ForEach(clipsOnMap) { clip in
                    if let coordinate = clip.mapCoordinate {
                        Annotation("", coordinate: coordinate) {
                            Button {
                                selectedClip = clip
                            } label: {
                                MapClipPinView(clip: clip)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clip on map")
                            .accessibilityIdentifier("map.clipPin")
                        }
                    }
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Near Me") {
                        toggleNearMe()
                    }
                    .fontWeight(isNearMeActive ? .semibold : .regular)
                    .accessibilityIdentifier("map.nearMe")
                    if let onSignOut {
                        Button("Sign Out", action: onSignOut)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isNearMeActive, clipsOnMap.isEmpty, viewModel.userCoordinate != nil {
                    Text("No clips within 25 km")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .accessibilityIdentifier("map.nearMeEmpty")
                }
            }
        }
        .accessibilityIdentifier("map.root")
        .onAppear {
            viewModel.onMapTabBecameActive()
        }
        .onChange(of: feedViewModel.videosWithMapCoordinates.count) { _, _ in
            if isNearMeActive {
                applyNearMeCamera()
            } else if let region = Self.regionFitting(feedViewModel.videosWithMapCoordinates) {
                position = .region(region)
            }
        }
        .sheet(item: $selectedClip) { clip in
            MapClipPreviewSheet(clip: clip) {
                onOpenClipInFeed(clip.id)
                selectedClip = nil
            }
        }
        .onChange(of: viewModel.cameraCenterGeneration) { _, _ in
            if isNearMeActive {
                applyNearMeCamera()
            } else if let region = viewModel.regionForCameraCenter() {
                position = .region(region)
            }
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

    private func toggleNearMe() {
        isNearMeActive.toggle()
        if isNearMeActive {
            if viewModel.userCoordinate == nil {
                viewModel.currentLocationButtonTapped()
            }
            applyNearMeCamera()
        } else if let region = Self.regionFitting(feedViewModel.videosWithMapCoordinates) {
            position = .region(region)
        }
    }

    private func applyNearMeCamera() {
        guard let user = viewModel.userCoordinate else { return }
        let region = MapClipProximity.regionFitting(user: user, clips: clipsOnMap)
        position = .region(region)
    }

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    )

    private static func regionFitting(_ clips: [FeedVideo]) -> MKCoordinateRegion? {
        let coordinates = clips.compactMap(\.mapCoordinate)
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else {
            return MKCoordinateRegion(
                center: first,
                span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
            )
        }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latitudeDelta = max(0.04, (maxLat - minLat) * 1.4)
        let longitudeDelta = max(0.04, (maxLon - minLon) * 1.4)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

private struct MapClipPreviewSheet: View {
    let clip: FeedVideo
    let onPlayInFeed: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            clipThumbnail
            if let latitude = clip.latitude, let longitude = clip.longitude {
                Text(String(format: "%.5f, %.5f", latitude, longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("Play in Feed", action: onPlayInFeed)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("map.playClipInFeed")
        }
        .padding(24)
        .presentationDetents([.height(280)])
        .task(id: clip.streamURL) {
            thumbnail = await VideoThumbnailLoader.shared.thumbnail(
                for: clip.streamURL,
                maxPixelSize: 320
            )
        }
    }

    @ViewBuilder
    private var clipThumbnail: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(white: 0.2)
                    .overlay { ProgressView() }
            }
        }
        .frame(width: 120, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .accessibilityLabel("Clip preview")
    }
}

#Preview {
    MapView(
        viewModel: MapViewModel(),
        feedViewModel: VideoFeedViewModel(fetchFeed: FetchFeedUseCase(repository: UITestFeedRepository())),
        onSignOut: nil,
        onOpenClipInFeed: { _ in }
    )
}
