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
    @State private var visibleRegion = Self.defaultRegion
    @State private var selectedClip: FeedVideo?
    @State private var isNearMeActive = false
    @State private var nearMeRadius = NearMeRadius.default
    @State private var isCountryFilterPresented = false
    @State private var searchText = ""

    /// All clips available on the map, honoring the country filter.
    private var allClips: [FeedVideo] {
        guard let country = viewModel.countryFilter else {
            return feedViewModel.videosWithMapCoordinates
        }
        return feedViewModel.mapFilteredClips.filter { $0.country == country }
    }

    /// Clips after the near-me radius is applied.
    private var nearMeClips: [FeedVideo] {
        guard isNearMeActive, let user = viewModel.userCoordinate else { return allClips }
        return MapClipProximity.clips(within: nearMeRadius.meters, of: user, from: allClips)
    }

    /// Clips that render as pins: near-me narrowed, then the search query.
    private var mapClips: [FeedVideo] {
        MapClipSearch.filter(nearMeClips, query: searchText)
    }

    private var clusteredClips: [MapClipCluster] {
        MapClipClustering.clusters(from: mapClips, in: visibleRegion)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                if viewModel.canShowUserOnMap {
                    UserAnnotation()
                }
                ForEach(clusteredClips) { cluster in
                    Annotation("", coordinate: cluster.coordinate) {
                        MapClusterPinView(cluster: cluster) {
                            handleClusterTap(cluster)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }

            VStack(spacing: 10) {
                topControls
                if isNearMeActive {
                    nearMeBanner
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            locateButton
                .padding(.trailing, 16)
                .padding(.bottom, 24)
        }
        .accessibilityIdentifier("map.root")
        .onAppear {
            viewModel.onMapTabBecameActive()
        }
        .onChange(of: allClips.count) { _, _ in
            if isNearMeActive {
                applyNearMeCamera()
            } else if let region = Self.regionFitting(allClips) {
                position = .region(region)
            }
        }
        .onChange(of: viewModel.countryFilter) { _, newValue in
            Task { await feedViewModel.loadMapClips(country: newValue) }
        }
        .onChange(of: nearMeRadius) { _, _ in
            guard isNearMeActive else { return }
            applyNearMeCamera()
        }
        .onChange(of: searchText) { _, _ in
            guard let region = Self.regionFitting(mapClips) else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                position = .region(region)
            }
        }
        .sheet(item: $selectedClip) { clip in
            MapClipPreviewSheet(clip: clip, userCoordinate: viewModel.userCoordinate) {
                onOpenClipInFeed(clip.id)
                selectedClip = nil
            }
        }
        .sheet(isPresented: $isCountryFilterPresented) {
            MapCountryFilterSheet(selection: $viewModel.countryFilter)
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

    /// The search pill is currently hidden (kept for later). Flip to `true` to
    /// bring back client-side clip search.
    private static let isSearchVisible = false

    private var topControls: some View {
        HStack(spacing: 10) {
            if Self.isSearchVisible {
                MapSearchBar(text: $searchText)
            } else {
                Spacer()
            }
            filtersMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var filtersMenu: some View {
        Menu {
            Button {
                isCountryFilterPresented = true
            } label: {
                Label(countryFilterMenuTitle, systemImage: "globe")
            }
            .accessibilityIdentifier("map.countryFilter")

            Button {
                toggleNearMe()
            } label: {
                Label(isNearMeActive ? "Hide clips near me" : "Clips near me",
                      systemImage: isNearMeActive ? "location.fill" : "location")
            }
            .accessibilityIdentifier("map.nearMe")

            if let onSignOut {
                Divider()
                Button("Sign Out", role: .destructive, action: onSignOut)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.quaternary, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .accessibilityLabel("Map filters")
        .accessibilityIdentifier("map.filters")
    }

    private var countryFilterMenuTitle: String {
        guard let country = viewModel.countryFilter else { return "All countries" }
        return CountryCatalog.name(for: country)
    }

    private var nearMeBanner: some View {
        VStack(spacing: 10) {
            Picker("Radius", selection: $nearMeRadius) {
                ForEach(NearMeRadius.allCases) { radius in
                    Text(radius.label).tag(radius)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("map.nearMeRadius")

            if nearMeClips.isEmpty, viewModel.userCoordinate != nil {
                Text(nearMeRadius.emptyClipsMessage)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityIdentifier("map.nearMeEmpty")
            }
        }
        .padding(.horizontal, 20)
    }

    private var locateButton: some View {
        Button {
            viewModel.currentLocationButtonTapped()
        } label: {
            Image(systemName: "location.fill")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.quaternary, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .accessibilityLabel("Current Location")
        .accessibilityIdentifier("map.currentLocation")
    }

    private func handleClusterTap(_ cluster: MapClipCluster) {
        guard cluster.isCluster else {
            if let clip = cluster.clips.first {
                selectedClip = clip
            }
            return
        }
        let span = MKCoordinateSpan(
            latitudeDelta: max(visibleRegion.span.latitudeDelta * 0.5, 0.004),
            longitudeDelta: max(visibleRegion.span.longitudeDelta * 0.5, 0.004)
        )
        withAnimation(.easeInOut(duration: 0.3)) {
            position = .region(MKCoordinateRegion(center: cluster.coordinate, span: span))
        }
    }

    private func toggleNearMe() {
        isNearMeActive.toggle()
        if isNearMeActive {
            if viewModel.userCoordinate == nil {
                viewModel.currentLocationButtonTapped()
            }
            applyNearMeCamera()
        } else if let region = Self.regionFitting(allClips) {
            position = .region(region)
        }
    }

    private func applyNearMeCamera() {
        guard let user = viewModel.userCoordinate else { return }
        let region = MapClipProximity.regionFitting(user: user, clips: nearMeClips)
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
    let userCoordinate: CLLocationCoordinate2D?
    let onPlayInFeed: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            clipThumbnail
            VStack(spacing: 4) {
                if let authorName = clip.authorName {
                    Text(authorName)
                        .font(.subheadline.weight(.semibold))
                }
                if let caption = clip.caption,
                   !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(caption)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                if let country = clip.country {
                    Text("\(Country.flagEmoji(for: country)) \(CountryCatalog.name(for: country))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let userCoordinate,
               let meters = MapClipProximity.distanceMeters(from: userCoordinate, to: clip) {
                Text(MapClipProximity.formattedDistance(meters))
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("map.clipDistance")
            }
            Button("Play in Feed", action: onPlayInFeed)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("map.playClipInFeed")
        }
        .padding(24)
        .presentationDetents([.height(320)])
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
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    let container = AppDependencyContainer()
    MapView(
        viewModel: MapViewModel(),
        feedViewModel: container.feedViewModel,
        onSignOut: {},
        onOpenClipInFeed: { _ in }
    )
}
