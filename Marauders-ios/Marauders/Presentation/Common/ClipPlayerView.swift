//
//  ClipPlayerView.swift
//  Marauders
//

import AVKit
import CoreLocation
import SwiftUI

/// Plays a single clip full-screen, looping until dismissed. Shared by the map
/// pins and the profile grid.
struct ClipPlayerView: View {
    let clip: FeedVideo
    var userCoordinate: CLLocationCoordinate2D?
    let onClose: () -> Void
    var onOpenInFeed: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .onAppear(perform: startPlayback)
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            player?.seek(to: .zero)
            player?.play()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let authorName = clip.authorName {
                    Text(authorName)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                if let country = clip.country {
                    Text("\(Country.flagEmoji(for: country)) \(CountryCatalog.name(for: country))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer()
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel("Delete clip")
                .accessibilityIdentifier("clip.delete")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Close video")
            .accessibilityIdentifier("clip.closeVideo")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption = clip.caption,
               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            if let musicTitle = clip.musicTitle,
               !musicTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(musicTitle, systemImage: "music.note")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("clip.music")
            }
            if let userCoordinate,
               let meters = MapClipProximity.distanceMeters(from: userCoordinate, to: clip) {
                Text(MapClipProximity.formattedDistance(meters))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("clip.distance")
            }
            if let onOpenInFeed {
                Button(action: onOpenInFeed) {
                    Label("Play in Feed", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clip.playInFeed")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func startPlayback() {
        guard player == nil else { return }
        let newPlayer = AVPlayer(url: clip.streamURL)
        newPlayer.actionAtItemEnd = .none
        player = newPlayer
        newPlayer.play()
    }
}
