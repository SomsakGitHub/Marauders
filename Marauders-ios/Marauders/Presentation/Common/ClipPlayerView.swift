//
//  ClipPlayerView.swift
//  Marauders
//

import AVKit
import CoreLocation
import SwiftUI
import Translation

/// Plays a single clip full-screen, looping until dismissed. Shared by the map
/// pins and the profile grid.
struct ClipPlayerView: View {
    let clip: FeedVideo
    var userCoordinate: CLLocationCoordinate2D?
    let onClose: () -> Void
    var onOpenInFeed: (() -> Void)?
    var onDelete: (() -> Void)?
    var requestThaiOnOpen = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var dubbing = ThaiDubbingViewModel()
    @State private var wantsThai = false
    @State private var audioRequestID = 0
    @State private var choosingAudio = false
    @State private var didChooseAudio = false
    @State private var hasThaiTrack = false
    @State private var resumeAfterInterruption = false
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
        .confirmationDialog("เลือกเสียงสำหรับคลิปนี้", isPresented: $choosingAudio, titleVisibility: .visible) {
            Button("ฟังเสียงต้นฉบับ") { wantsThai = false; dubbing.useOriginal() }
            Button("แปลเป็นเสียงไทยด้วย AI") { audioRequestID += 1; wantsThai = true }
            Button("ยกเลิก", role: .cancel) {}
        } message: {
            Text("ถอดคำพูดอังกฤษ แปลและสร้างเสียงไทยบน iPhone อาจต้องดาวน์โหลดภาษาครั้งแรก เสียงอ่านอาจไม่ตรงจังหวะคำพูดเดิม")
        }
        .onAppear {
            startPlayback()
            if !didChooseAudio {
                didChooseAudio = true
                if requestThaiOnOpen { wantsThai = true } else { choosingAudio = true }
            }
        }
        .task(id: "\(wantsThai):\(audioRequestID)") {
            if wantsThai {
                if AppRuntimeConfiguration.isUITesting {
                    dubbing.unavailableForTesting()
                } else {
                    translationConfiguration = .init(source: .init(identifier: "en"), target: .init(identifier: "th"), preferredStrategy: .lowLatency)
                    translationConfiguration?.invalidate()
                }
            } else {
                translationConfiguration = nil
                dubbing.useOriginal()
                if hasThaiTrack { restoreOriginalTrack() }
            }
        }
        .translationTask(translationConfiguration) { session in
            if let url = await dubbing.request(sourceURL: clip.streamURL, session: session), wantsThai, !Task.isCancelled {
                await useThaiTrack(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive {
                resumeAfterInterruption = player?.timeControlStatus == .playing
                player?.pause()
            } else if phase == .background {
                resumeAfterInterruption = false
                player?.pause()
                wantsThai = false
                translationConfiguration = nil
                dubbing.useOriginal()
            } else if resumeAfterInterruption {
                resumeAfterInterruption = false
                player?.play()
            }
        }
        .onDisappear { translationConfiguration = nil; dubbing.useOriginal(); player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            player?.seek(to: .zero)
            if scenePhase == .active { player?.play() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { note in
            guard hasThaiTrack, let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            restoreOriginalTrack()
            wantsThai = false
            dubbing.playbackFailed()
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
            Button { choosingAudio = true } label: {
                Label(hasThaiTrack ? "เสียงไทยจาก AI · เปลี่ยนเสียง" : "เสียงต้นฉบับ · เลือกเสียง", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("clip.chooseAudio")
            if let message = dubbing.message {
                HStack {
                    if dubbing.isProcessing { ProgressView().tint(.white) }
                    Text(message).font(.caption).foregroundStyle(.white)
                }
                .accessibilityIdentifier("clip.dubbingStatus")
            }

            if let caption = clip.caption,
               !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            if let userCoordinate,
               let meters = MapClipProximity.distanceMeters(from: userCoordinate, to: clip) {
                Text(MapClipProximity.formattedDistance(meters))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("clip.distance")
            }
            if let coordinate = clip.mapCoordinate,
               let mapsURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(coordinate.latitude),\(coordinate.longitude)") {
                Link(destination: mapsURL) {
                    Label("Open in Google Maps", systemImage: "map")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
                .accessibilityIdentifier("clip.openGoogleMaps")
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

    private func restoreOriginalTrack() {
        guard let player else { return }
        let time = player.currentTime()
        let playing = player.timeControlStatus == .playing
        player.replaceCurrentItem(with: AVPlayerItem(url: clip.streamURL))
        player.seek(to: time)
        if playing, scenePhase == .active { player.play() }
        hasThaiTrack = false
    }

    private func useThaiTrack(_ url: URL) async {
        do {
            let original = AVURLAsset(url: clip.streamURL)
            let translated = AVURLAsset(url: url)
            guard let video = try await original.loadTracks(withMediaType: .video).first,
                  let audio = try await translated.loadTracks(withMediaType: .audio).first else { throw ThaiDubbingError.failed }
            let duration = try await original.load(.duration)
            let audioDuration = try await translated.load(.duration)
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ThaiDubbingError.failed }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
            videoTrack.preferredTransform = try await video.load(.preferredTransform)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audio, at: .zero)
            // Preserve the complete translated speech when Thai narration runs longer.
            if CMTimeCompare(audioDuration, duration) > 0 {
                audioTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: audioDuration), toDuration: duration)
            }
            try Task.checkCancellation()
            guard wantsThai, let player else { return }
            let time = CMTime.zero
            let playing = player.timeControlStatus == .playing
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            hasThaiTrack = true
            await player.seek(to: time)
            guard !Task.isCancelled, wantsThai else { return }
            if playing, scenePhase == .active { player.play() }
        } catch is CancellationError { }
        catch { dubbing.playbackFailed() }
    }

    private func startPlayback() {
        guard player == nil else { return }
        let newPlayer = AVPlayer(url: clip.streamURL)
        newPlayer.actionAtItemEnd = .none
        player = newPlayer
        newPlayer.play()
    }
}
