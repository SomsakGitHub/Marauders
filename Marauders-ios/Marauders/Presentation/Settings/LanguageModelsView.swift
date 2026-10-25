//
//  LanguageModelsView.swift
//  Marauders
//

import SwiftUI
@preconcurrency import Translation

struct LanguageModelsView: View {
    @Bindable var viewModel: LanguageModelsViewModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                ForEach(viewModel.translationModels) { row($0) }
            } header: {
                Text("Translation")
            } footer: {
                Text("Apple downloads translation languages through a system prompt. Remove them in iOS Settings → Apps → Translate.")
            }

            Section {
                ForEach(viewModel.speechModels) { row($0) }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Models run on this device. Audio and transcripts are not uploaded. Downloads need a network connection and free storage.")
            }
        }
        .navigationTitle("Language models")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("languageModels.root")
        .task { await viewModel.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await viewModel.refresh() } }
        }
        .refreshable { await viewModel.refresh() }
        .onDisappear { Task { await viewModel.abandonTranslationDownload() } }
        .translationTask(viewModel.translationConfiguration) { session in
            await viewModel.prepareTranslation(session)
        }
    }

    private func row(_ model: LanguageModel) -> some View {
        let status = viewModel.status(of: model)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                Text(subtitle(for: model, status: status))
                    .font(.footnote)
                    .foregroundStyle(isFailure(status) ? Color.red : Color.secondary)
            }
            Spacer(minLength: 8)
            trailing(for: model, status: status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("languageModels.\(model.id)")
        .swipeActions {
            if viewModel.canRemove(model) {
                Button("Remove", role: .destructive) {
                    Task { await viewModel.remove(model) }
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(for model: LanguageModel, status: LanguageModelStatus) -> some View {
        switch status {
        case .checking:
            ProgressView()
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        case .notInstalled:
            downloadButton(model, title: "Download")
        case .failed:
            downloadButton(model, title: "Retry")
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
            }
        case .unsupported:
            Text("Unavailable")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func downloadButton(_ model: LanguageModel, title: String) -> some View {
        Button(title) {
            Task { await viewModel.download(model) }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("languageModels.download.\(model.id)")
    }

    private func subtitle(for model: LanguageModel, status: LanguageModelStatus) -> String {
        switch status {
        case .failed(let message): message
        case .downloading(let progress?): "Downloading… \(Int(progress * 100))%"
        case .downloading(nil): "Downloading…"
        case .unsupported: "Not supported on this device"
        default: model.detail
        }
    }

    private func isFailure(_ status: LanguageModelStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }
}

#Preview {
    NavigationStack {
        LanguageModelsView(viewModel: LanguageModelsViewModel(manager: NoopLanguageModelManager()))
    }
}
