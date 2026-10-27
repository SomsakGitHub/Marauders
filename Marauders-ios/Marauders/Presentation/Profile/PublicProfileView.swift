//
//  PublicProfileView.swift
//  Marauders
//

import SwiftUI

/// Another user's public profile, presented when an author handle is tapped.
struct PublicProfileView: View {
    @Bindable var viewModel: PublicProfileViewModel
    var onClose: () -> Void

    @State private var selectedClip: FeedVideo?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    errorState(message)
                case .loaded:
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("publicProfile.close")
                }
            }
        }
        .accessibilityIdentifier("publicProfile.root")
        .task {
            await viewModel.loadIfNeeded()
        }
        .fullScreenCover(item: $selectedClip) { clip in
            ClipPlayerView(
                clip: clip,
                onClose: { selectedClip = nil }
            )
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if viewModel.clips.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
        .refreshable {
            await viewModel.reload()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(
                url: viewModel.profile?.avatarURL,
                handle: viewModel.profile?.handle ?? viewModel.handle,
                size: 76
            )

            Text(viewModel.profile?.handle ?? viewModel.handle)
                .font(.headline)
                .accessibilityIdentifier("publicProfile.handle")

            if let country = viewModel.profile?.country, !country.isEmpty {
                Text("\(Country.flagEmoji(for: country)) \(CountryCatalog.name(for: country))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("publicProfile.country")
            }

            Text(clipCountLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var clipCountLabel: String {
        let count = viewModel.profile?.videoCount ?? 0
        return count == 1 ? "1 clip" : "\(count) clips"
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(viewModel.clips) { clip in
                Button {
                    selectedClip = clip
                } label: {
                    ProfileClipThumbnail(clip: clip)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("publicProfile.clip")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No clips yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("publicProfile.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
