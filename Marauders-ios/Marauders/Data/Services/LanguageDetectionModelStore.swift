//
//  LanguageDetectionModelStore.swift
//  Marauders
//

import CoreML
import Foundation
@preconcurrency import WhisperKit

enum LanguageDetectionModelError: LocalizedError, Equatable {
    case incompleteDownload
    case unusable

    var errorDescription: String? {
        switch self {
        case .incompleteDownload: String(localized: "The download didn't finish. Try again.")
        case .unusable: String(localized: "The downloaded model couldn't be used on this iPhone. Try again.")
        }
    }
}

/// Keeps the language detection model (Whisper base, converted for Core ML) on this iPhone.
///
/// Everything lives in one folder under Application Support that is excluded from backups, because it
/// can be downloaded again. The folder is named after the pinned revisions of the model and its
/// tokenizer, so a build of the app that pins other files starts clean and removes the old ones. A
/// marker file is written last, so a download that stopped halfway never counts as installed.
actor LanguageDetectionModelStore: LanguageDetectionModelManaging {
    static let shared = LanguageDetectionModelStore()

    /// The exact files this build of the app was tested with, taken from Hugging Face at a fixed commit.
    nonisolated struct Release: Sendable {
        let modelRepo: String
        let modelRevision: String
        let modelFolderName: String
        let tokenizerRepo: String
        let tokenizerRevision: String

        static let current = Release(
            modelRepo: "argmaxinc/whisperkit-coreml",
            modelRevision: "0f63a7800b00dd0226abd051b906c246e1907482",
            modelFolderName: "openai_whisper-base",
            tokenizerRepo: "openai/whisper-base",
            tokenizerRevision: "e37978b90ca9030d5170a5c07aadb050351a65bb"
        )

        var directoryName: String { "\(modelRevision.prefix(8))-\(tokenizerRevision.prefix(8))" }
    }

    /// Where an installed model and its tokenizer are.
    nonisolated struct Folders: Sendable {
        let model: URL
        /// Hub-style base folder; the tokenizer is found underneath it without any network request.
        let tokenizerBase: URL
    }

    private nonisolated struct Marker: Codable {
        let modelRevision: String
        let tokenizerRevision: String
    }

    /// The mel spectrogram stays off the GPU, so nothing breaks if the app moves to the background mid-check.
    static let computeOptions = ModelComputeOptions(
        melCompute: .cpuOnly,
        audioEncoderCompute: .cpuAndNeuralEngine,
        textDecoderCompute: .cpuAndNeuralEngine
    )

    /// What an install does between preparing the folder and writing the marker: download, check and
    /// prepare the files inside `base`. Tests replace it so no network is needed.
    typealias Installer = @Sendable (_ base: URL, _ release: Release, _ report: @escaping @Sendable (Double) -> Void) async throws -> Void

    private let release: Release
    private let root: URL
    private let installer: Installer?
    /// The share of the progress bar taken by downloading the model; the rest is checking and preparing it.
    static let downloadShare = 0.9

    private var installTask: Task<Void, Never>?
    private var installToken: UUID?
    private var removal: Task<Void, Never>?
    private var removalToken: UUID?
    private var fraction = 0.0
    private var observers: [UUID: @Sendable (Double) -> Void] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(release: Release = .current, root: URL? = nil, installer: Installer? = nil) {
        self.release = release
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "LanguageDetection", directoryHint: .isDirectory)
        self.installer = installer
    }

    // MARK: - State

    func isInstalled() -> Bool { installedFolders() != nil }

    func status() -> LanguageModelStatus {
        if installTask != nil { return .downloading(progress: fraction) }
        return isInstalled() ? .installed : .notInstalled
    }

    /// The folders to load the model from, or nil unless the install finished and the files are there.
    func installedFolders() -> Folders? {
        guard let marker = readMarker(),
              marker.modelRevision == release.modelRevision,
              marker.tokenizerRevision == release.tokenizerRevision else { return nil }
        return completeFolders()
    }

    // MARK: - Install and remove

    /// Waits for the install, starting it if none is running. The download belongs to the store, not to the
    /// caller: a viewer who leaves the player does not stop a download they agreed to, and the next caller
    /// joins it. A caller that is cancelled stops waiting at once.
    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        // A removal in progress is still deleting the folder this install would write into.
        if let removal { await removal.value }
        if isInstalled() {
            progress(1)
            return
        }
        let id = UUID()
        observers[id] = progress
        startInstallIfNeeded()
        progress(fraction)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters[id] = continuation
                }
            } onCancel: {
                Task { await self.leave(id) }
            }
        } catch {
            observers[id] = nil
            throw error
        }
        observers[id] = nil
    }

    /// Stops a running install, waits for it to wind down, and deletes everything. An install asked for
    /// while this is still deleting waits for it to finish, so it never writes into a folder that is
    /// about to disappear.
    func remove() async {
        let task = installTask
        installTask = nil
        installToken = nil
        fraction = 0
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        let token = UUID()
        removalToken = token
        let removing = Task { [self] in
            task?.cancel()
            await task?.value
            deleteEverything()
        }
        removal = removing
        await removing.value
        if removalToken == token {
            removal = nil
            removalToken = nil
        }
    }

    /// The marker goes first, so a marker that is there always means a finished install, even if the
    /// deletion is cut short.
    private func deleteEverything() {
        try? FileManager.default.removeItem(at: markerURL)
        try? FileManager.default.removeItem(at: root)
    }

    private func startInstallIfNeeded() {
        guard installTask == nil else { return }
        fraction = 0
        let token = UUID()
        installToken = token
        installTask = Task { [self] in
            do {
                try await performInstall(token: token)
                finishInstall(token, .success(()))
            } catch {
                finishInstall(token, .failure(error))
            }
        }
    }

    /// Only the install that is still current may finish: after `remove()` and a new install, a late
    /// result from the old one must not clear the new one's state.
    private func finishInstall(_ token: UUID, _ result: Result<Void, Error>) {
        guard installToken == token else { return }
        installTask = nil
        installToken = nil
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume(with: result) }
    }

    private func leave(_ id: UUID) {
        observers[id] = nil
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Progress from an install that has been removed or replaced is ignored.
    private func report(_ value: Double, token: UUID) {
        guard installToken == token else { return }
        fraction = max(fraction, min(value, 1))
        let current = fraction
        for observer in observers.values { observer(current) }
    }

    private func performInstall(token: UUID) async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markerURL)
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        removeOtherReleases()

        if let installer {
            try await installer(base, release) { value in Task { await self.report(value, token: token) } }
        } else {
            try await downloadAndPrepare(token: token)
        }
        try Task.checkCancellation()
        guard installToken == token else { throw CancellationError() }
        try writeMarker()
        report(1, token: token)
    }

    /// Downloads the pinned files, checks them and lets Core ML prepare the model for this chip.
    private func downloadAndPrepare(token: UUID) async throws {
        let manager = FileManager.default
        let hub = HubApiWrapper(downloadBase: base)
        // The model is almost all of the download, so it takes most of the progress bar.
        _ = try await hub.snapshot(
            from: HubApiWrapper.Repo(id: release.modelRepo),
            revision: release.modelRevision,
            matching: ["\(release.modelFolderName)/*"]
        ) { progress in
            let value = progress.fractionCompleted * Self.downloadShare
            Task { await self.report(value, token: token) }
        }
        try Task.checkCancellation()
        _ = try await hub.snapshot(
            from: HubApiWrapper.Repo(id: release.tokenizerRepo),
            revision: release.tokenizerRevision,
            matching: ["config.json", "tokenizer_config.json", "tokenizer.json"]
        )
        report(Self.downloadShare + 0.02, token: token)
        try Task.checkCancellation()

        guard let folders = completeFolders() else {
            // What arrived is not what was asked for; start over next time.
            try? manager.removeItem(at: base)
            throw LanguageDetectionModelError.incompleteDownload
        }
        // WhisperKit goes back to Hugging Face (and the unpinned main branch) if it cannot read the local
        // tokenizer, so make sure it can now, while the viewer is waiting for the install anyway.
        let tokenizerFolder = hub.localRepoLocation(HubApiWrapper.Repo(id: release.tokenizerRepo))
        do {
            _ = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder, hubApi: hub)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LanguageDetectionModelError.unusable
        }
        // Core ML prepares the model for this chip the first time it loads; doing it now keeps the first check fast.
        // The files stay in place if this fails, so trying again does not download everything a second time.
        do {
            _ = try await WhisperKit(WhisperKitConfig(
                modelFolder: folders.model.path,
                tokenizerFolder: folders.tokenizerBase,
                computeOptions: Self.computeOptions,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: false,
                download: false
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LanguageDetectionModelError.unusable
        }
        report(0.99, token: token)
    }

    // MARK: - Files

    /// Where an install puts its files, so tests can build a finished install without a download.
    func layout() -> (model: URL, tokenizer: URL, marker: URL) {
        let hub = HubApiWrapper(downloadBase: base)
        return (
            hub.localRepoLocation(HubApiWrapper.Repo(id: release.modelRepo)).appending(path: release.modelFolderName, directoryHint: .isDirectory),
            hub.localRepoLocation(HubApiWrapper.Repo(id: release.tokenizerRepo)),
            markerURL
        )
    }

    private var base: URL { root.appending(path: release.directoryName, directoryHint: .isDirectory) }
    private var markerURL: URL { base.appending(path: "installed.json") }

    private func completeFolders() -> Folders? {
        let hub = HubApiWrapper(downloadBase: base)
        let model = hub.localRepoLocation(HubApiWrapper.Repo(id: release.modelRepo)).appending(path: release.modelFolderName, directoryHint: .isDirectory)
        let tokenizer = hub.localRepoLocation(HubApiWrapper.Repo(id: release.tokenizerRepo))
        let manager = FileManager.default
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] where !manager.fileExists(atPath: model.appending(path: "\(name).mlmodelc").path) {
            return nil
        }
        guard manager.fileExists(atPath: tokenizer.appending(path: "tokenizer.json").path) else { return nil }
        return Folders(model: model, tokenizerBase: base)
    }

    private func readMarker() -> Marker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private func writeMarker() throws {
        let marker = Marker(modelRevision: release.modelRevision, tokenizerRevision: release.tokenizerRevision)
        try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
    }

    /// Older pinned releases are not used by this build, so their files are only taking up space.
    private func removeOtherReleases() {
        let manager = FileManager.default
        let others = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in others where url.lastPathComponent != release.directoryName {
            try? manager.removeItem(at: url)
        }
    }
}
