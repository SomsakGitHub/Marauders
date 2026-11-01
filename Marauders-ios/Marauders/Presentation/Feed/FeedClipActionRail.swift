//
//  FeedClipActionRail.swift
//  Marauders
//

import SwiftUI

/// Right-edge action rail for the current clip (TikTok-style). It hosts the like and comments buttons,
/// the audio choice and the creator's avatar, which opens their public profile when tapped.
struct FeedClipActionRail: View {
    let clip: FeedVideo
    /// Called with the language the viewer picked to hear the clip in.
    var onChooseAIAudio: ((ListeningLanguage) -> Void)? = nil
    var onAuthorTap: ((String) -> Void)?

    var canChooseAudio = true
    var onRequireSignIn: (() -> Void)? = nil
    var onAudioSelectionChanged: (Bool) -> Void = { _ in }
    /// Set only while an AI dubbed track is playing for this clip; the dialog then offers to report it.
    /// The feed itself plays the original audio, so it leaves this nil.
    var onReportAudio: (() -> Void)? = nil
    /// Opens the clip's comments. Without it the rail has no comments button.
    var onOpenComments: (() -> Void)? = nil
    /// How many comments the clip has, shown under the comments button; without it the button says "Comments".
    var commentCount: Int? = nil
    /// What the viewer sees on the like button. Without it, or without `onToggleLike`, the rail has no like button.
    var like: ClipLikeState? = nil
    var onToggleLike: (() -> Void)? = nil
    /// Goes up each time the viewer likes the clip, from the heart or a double tap: the heart bounces then.
    var likePops = 0

    @State private var choosingAudio = false
    @State private var showingLanguagePicker = false
    @State private var languagePicker = ListeningLanguagePickerViewModel()
    private let listening = ListeningLanguageStore.shared

    var body: some View {
        VStack(spacing: 20) {
            if let like, let onToggleLike {
                Button(action: onToggleLike) {
                    VStack(spacing: 4) {
                        // A filled heart either way, as on TikTok: white until the viewer likes the clip.
                        Image(systemName: "heart.fill")
                            .font(.title2)
                            .foregroundStyle(like.liked ? Color.likeRed : Color.white)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .symbolEffect(.bounce, value: likePops)
                            .animation(.snappy, value: like.liked)
                        Text(like.count.formatted(.number.notation(.compactName))).font(.caption)
                    }.foregroundStyle(.white)
                }
                .accessibilityIdentifier("feed.like")
                .accessibilityLabel(like.liked ? Text("Unlike") : Text("Like"))
                .accessibilityValue(like.count.formatted())
            }

            if let onOpenComments {
                Button(action: onOpenComments) {
                    VStack(spacing: 4) {
                        Image(systemName: "bubble.right").font(.title2)
                        if let commentCount {
                            Text(commentCount.formatted(.number.notation(.compactName))).font(.caption)
                        } else {
                            Text("Comments").font(.caption)
                        }
                    }.foregroundStyle(.white)
                }
                .accessibilityIdentifier("feed.comments")
                .accessibilityLabel(Text("Comments"))
                .accessibilityValue(commentCount?.formatted() ?? "")
            }

            if let onChooseAIAudio, listening.offersDubbing(for: clip) {
                Button {
                    onAudioSelectionChanged(true)
                    if canChooseAudio { choosingAudio = true } else { onRequireSignIn?() }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "waveform").font(.title2)
                        Text("Choose audio").font(.caption)
                    }.foregroundStyle(.white)
                }
                .accessibilityIdentifier("feed.chooseAudio")
                .onChange(of: choosingAudio) { _, open in
                    // The language sheet keeps the feed paused, so it reports the close itself.
                    if !open, !showingLanguagePicker { onAudioSelectionChanged(false) }
                }
                .onChange(of: showingLanguagePicker) { _, open in
                    if !open { onAudioSelectionChanged(false) }
                }
                .confirmationDialog("Choose audio for this clip", isPresented: $choosingAudio, titleVisibility: .visible) {
                    Button("Original audio") {}
                    ForEach(listening.targets(for: clip)) { target in
                        Button("Listen in \(target.sentenceName()) (AI)") { onChooseAIAudio(target) }
                    }
                    if let onReportAudio {
                        Button("Report this audio", role: .destructive) { onReportAudio() }
                    }
                    Button("Change listening language…") { showingLanguagePicker = true }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("AI dubbing is created on your iPhone and saved so other viewers can reuse it.")
                }
                .sheet(isPresented: $showingLanguagePicker) {
                    NavigationStack {
                        ListeningLanguagePickerView(viewModel: languagePicker) {
                            showingLanguagePicker = false
                            // Choosing a language starts dubbing in it, unless it is the clip's own.
                            if let chosen = listening.targets(for: clip).first { onChooseAIAudio(chosen) }
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showingLanguagePicker = false }
                            }
                        }
                    }
                }
            }

            if let handle = clip.authorName {
                Button {
                    onAuthorTap?(handle)
                } label: {
                    AvatarView(url: clip.authorAvatarURL, handle: handle, size: 48)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.avatar")
                .accessibilityLabel("Open \(handle) profile")
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
