//
//  ProfileView.swift
//  Marauders
//

import SwiftUI

struct ProfileView: View {
    @Bindable var viewModel: ProfileViewModel
    var onSignOut: () -> Void

    @State private var selectedClip: FeedVideo?
    @State private var pendingDeletion: FeedVideo?
    @State private var isEditingHandle = false
    @State private var handleDraft = ""

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
            .confirmationDialog(
                "Delete this clip?",
                isPresented: deletionBinding,
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { clip in
                Button("Delete", role: .destructive) {
                    Task { await viewModel.delete(clip) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This cannot be undone.")
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out", action: onSignOut)
                        .accessibilityIdentifier("profile.signOut")
                }
            }
            .alert("Edit handle", isPresented: $isEditingHandle) {
                TextField("@handle", text: $handleDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("profile.handleField")
                Button("Save") {
                    Task { await viewModel.updateHandle(handleDraft) }
                }
                .accessibilityIdentifier("profile.handleSave")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Letters, numbers, dots and underscores.")
            }
            .alert("Couldn't update handle", isPresented: handleErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.handleErrorMessage ?? "")
            }
        }
        .accessibilityIdentifier("profile.root")
        .task {
            await viewModel.loadIfNeeded()
        }
        .fullScreenCover(item: $selectedClip) { clip in
            ClipPlayerView(
                clip: clip,
                onClose: { selectedClip = nil },
                onDelete: {
                    selectedClip = nil
                    pendingDeletion = clip
                }
            )
        }
        .alert("Couldn't delete clip", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.deleteErrorMessage ?? "")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.deleteErrorMessage != nil },
            set: { if !$0 { viewModel.clearDeleteError() } }
        )
    }

    private var handleErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.handleErrorMessage != nil },
            set: { if !$0 { viewModel.clearHandleError() } }
        )
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
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(.secondary)

            Button {
                handleDraft = viewModel.handle
                isEditingHandle = true
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.handle)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.handle")

            if let country = viewModel.profile?.country, !country.isEmpty {
                Text("\(Country.flagEmoji(for: country)) \(CountryCatalog.name(for: country))")
                    .font(.headline)
                    .accessibilityIdentifier("profile.country")
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
                .accessibilityIdentifier("profile.clip")
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDeletion = clip
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("profile.clip.delete")
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No clips yet")
                .font(.headline)
            Text("Clips you upload will show up here.")
                .font(.footnote)
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
            .accessibilityIdentifier("profile.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProfileClipThumbnail: View {
    let clip: FeedVideo

    @State private var thumbnail: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(white: 0.25)
                        .overlay { ProgressView().tint(.white) }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: clip.streamURL) {
                thumbnail = await VideoThumbnailLoader.shared.thumbnail(
                    for: clip.streamURL,
                    maxPixelSize: 240
                )
            }
    }
}
