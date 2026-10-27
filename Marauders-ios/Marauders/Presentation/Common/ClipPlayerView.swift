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
    /// When set, the author's handle opens their profile.
    var onOpenAuthor: ((String) -> Void)?
    var onDelete: (() -> Void)?
    /// When set, dubbing into this language starts as soon as the player opens.
    var requestDubbingTarget: ListeningLanguage?

    @Environment(\.scenePhase) private var scenePhase
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var dubbing = DubbingViewModel()
    @State private var dubbingTarget: ListeningLanguage?
    @State private var dubbingSource: DubbingSourceLanguage?
    @State private var showingLanguagePicker = false
    @State private var offeringDetectionModel = false
    /// Set by the alert's Download button and used up by the next preparation, nowhere else.
    @State private var detectionModelAgreed = false
    /// The language whose speech model (the Whisper model) the viewer is being asked about, and their answer.
    @State private var offeredSpeechModel: DubbingSourceLanguage?
    @State private var speechModelAgreed = false
    @State private var languagePicker = ListeningLanguagePickerViewModel()
    @State private var wantsDubbing = false
    @State private var audioRequestID = 0
    @State private var choosingAudio = false
    @State private var didChooseAudio = false
    @State private var hasDubbedTrack = false
    @State private var resumeAfterInterruption = false
    @State private var player: AVPlayer?
    private let listening = ListeningLanguageStore.shared

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
        .confirmationDialog("Choose audio for this clip", isPresented: $choosingAudio, titleVisibility: .visible) {
            Button("Original audio") { wantsDubbing = false; dubbing.useOriginal() }
            if clip.allowsAIAudio {
                ForEach(listening.targets(for: clip)) { target in
                    Button("Listen in \(target.sentenceName()) (AI)") { startDubbing(in: target) }
                }
            }
            Button("Change listening language…") { showingLanguagePicker = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI dubbing is created on your iPhone and saved so other viewers can reuse it. It may be inaccurate or out of sync with the original.")
        }
        .sheet(isPresented: $showingLanguagePicker) {
            NavigationStack {
                ListeningLanguagePickerView(viewModel: languagePicker, onChosen: languageChosen)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingLanguagePicker = false }
                        }
                    }
            }
        }
        .alert("Download the language detection model?", isPresented: $offeringDetectionModel) {
            Button("Download (about \(LanguageDetectionModel.approximateMegabytes) MB)") {
                detectionModelAgreed = true
                audioRequestID += 1
            }
            Button("Not now", role: .cancel) {
                LanguageDetectionConsent.shared.decline()
                audioRequestID += 1
            }
        } message: {
            Text("To tell which language this clip speaks, your iPhone needs a model of about \(LanguageDetectionModel.approximateMegabytes) MB from Hugging Face (use Wi-Fi if you can). It runs on your iPhone and your audio is not uploaded. Without it, your iPhone can mainly recognize English and Spanish.")
        }
        .alert(
            "Download the \(offeredSpeechModel?.displayName() ?? "") speech model?",
            isPresented: Binding(get: { offeredSpeechModel != nil }, set: { if !$0 { offeredSpeechModel = nil } }),
            presenting: offeredSpeechModel
        ) { language in
            Button("Download (about \(LanguageDetectionModel.approximateMegabytes) MB)") {
                speechModelAgreed = true
                audioRequestID += 1
            }
            Button("Not now", role: .cancel) { dubbing.declineSpeechModel(for: language) }
        } message: { language in
            Text("To dub this clip, your iPhone needs a \(language.displayName()) speech model of about \(LanguageDetectionModel.approximateMegabytes) MB from Hugging Face (use Wi-Fi if you can). It runs on your iPhone and your audio is not uploaded. It is the same model that tells which language a clip speaks.")
        }
        .onAppear {
            startPlayback()
            if !didChooseAudio, listening.offersDubbing(for: clip) {
                didChooseAudio = true
                if let requestDubbingTarget { startDubbing(in: requestDubbingTarget) } else { choosingAudio = true }
            }
        }
        .task(id: "\(wantsDubbing):\(audioRequestID)") {
            let agreedToDetectionModel = detectionModelAgreed
            detectionModelAgreed = false
            let agreedToSpeechModel = speechModelAgreed
            speechModelAgreed = false
            if wantsDubbing, clip.allowsAIAudio, let target = dubbingTarget {
                translationConfiguration = nil
                if AppRuntimeConfiguration.isUITesting {
                    dubbing.unavailableForTesting()
                    return
                }
                let plan = await dubbing.prepare(clip: clip, target: target, downloadingDetectionModel: agreedToDetectionModel,
                                                 downloadingSpeechModel: agreedToSpeechModel)
                guard wantsDubbing, !Task.isCancelled else { return }
                switch plan {
                case .cached(let audio):
                    await useDubbedTrack(audio)
                case .translate(let source):
                    dubbingSource = source
                    translationConfiguration = .init(source: .init(identifier: source.translationCode), target: .init(identifier: target.code), preferredStrategy: .lowLatency)
                    translationConfiguration?.invalidate()
                case .needsDetectionModel:
                    offeringDetectionModel = true
                case .needsSpeechModel(let language):
                    offeredSpeechModel = language
                case .unavailable:
                    // The status line says why; the original audio keeps playing.
                    break
                }
            } else {
                translationConfiguration = nil
                dubbing.useOriginal()
                if hasDubbedTrack { restoreOriginalTrack() }
            }
        }
        .translationTask(translationConfiguration) { session in
            guard wantsDubbing, clip.allowsAIAudio, let target = dubbingTarget, let source = dubbingSource, !Task.isCancelled else { return }
            if let url = await dubbing.request(sourceURL: clip.streamURL, session: session, source: source, target: target), wantsDubbing, !Task.isCancelled {
                await useDubbedTrack(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive {
                resumeAfterInterruption = player?.timeControlStatus == .playing
                player?.pause()
            } else if phase == .background {
                resumeAfterInterruption = false
                player?.pause()
                wantsDubbing = false
                // An open question about the download would otherwise outlive the request it belonged to.
                offeringDetectionModel = false
                offeredSpeechModel = nil
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
            guard hasDubbedTrack, let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            restoreOriginalTrack()
            wantsDubbing = false
            dubbing.playbackFailed()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let authorName = clip.authorName {
                    if let onOpenAuthor {
                        Button {
                            onOpenAuthor(authorName)
                        } label: {
                            Text(authorName)
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("clip.author")
                    } else {
                        Text(authorName)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
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
        .padding(.top, 28)
        .padding(.bottom, 16)
        .background(alignment: .top) {
            // Keeps the white handle readable over bright video and gives it room below the top edge.
            LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if listening.offersDubbing(for: clip) {
                Button { choosingAudio = true } label: {
                    Label(audioButtonTitle, systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clip.chooseAudio")
            }
            if let message = dubbing.message {
                HStack {
                    if dubbing.isProcessing { ProgressView().tint(.white) }
                    Text(message).font(.caption).foregroundStyle(.white)
                }
                .accessibilityIdentifier("clip.dubbingStatus")
            }

            if hasDubbedTrack, let subtitle = dubbing.subtitle {
                Text(subtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("clip.dubbingSubtitle")
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

    private var audioButtonTitle: String {
        if hasDubbedTrack, let target = dubbingTarget {
            return String(localized: "AI audio in \(target.sentenceName()) · Change audio")
        }
        return String(localized: "Original audio · Choose audio")
    }

    /// Starts dubbing into `target`, the language the viewer just picked.
    private func startDubbing(in target: ListeningLanguage) {
        dubbingTarget = target
        audioRequestID += 1
        wantsDubbing = true
    }

    private func languageChosen() {
        showingLanguagePicker = false
        if let chosen = listening.targets(for: clip).first {
            startDubbing(in: chosen)
        } else {
            // The chosen language is the one already spoken in the clip.
            wantsDubbing = false
            dubbing.useOriginal()
            if hasDubbedTrack { restoreOriginalTrack() }
        }
    }

    private func restoreOriginalTrack() {
        guard let player else { return }
        let time = player.currentTime()
        let playing = player.timeControlStatus == .playing
        player.replaceCurrentItem(with: AVPlayerItem(url: clip.streamURL))
        player.seek(to: time)
        if playing, scenePhase == .active { player.play() }
        hasDubbedTrack = false
    }

    private func useDubbedTrack(_ url: URL) async {
        do {
            let original = AVURLAsset(url: clip.streamURL)
            let translated = AVURLAsset(url: url)
            guard let video = try await original.loadTracks(withMediaType: .video).first,
                  let audio = try await translated.loadTracks(withMediaType: .audio).first else { throw DubbingError.failed }
            let duration = try await original.load(.duration)
            let audioDuration = try await translated.load(.duration)
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw DubbingError.failed }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
            videoTrack.preferredTransform = try await video.load(.preferredTransform)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audio, at: .zero)
            // Preserve the complete translated speech when the narration runs longer.
            if CMTimeCompare(audioDuration, duration) > 0 {
                audioTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: audioDuration), toDuration: duration)
            }
            try Task.checkCancellation()
            guard wantsDubbing, let player else { return }
            let time = CMTime.zero
            let playing = player.timeControlStatus == .playing
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            hasDubbedTrack = true
            await player.seek(to: time)
            guard !Task.isCancelled, wantsDubbing else { return }
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
