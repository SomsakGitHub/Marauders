import Foundation
import Testing
@testable import Marauders

struct LanguageDetectionModelStoreTests {
    private func makeStore() -> (store: LanguageDetectionModelStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detection-\(UUID().uuidString)", isDirectory: true)
        return (LanguageDetectionModelStore(root: root), root)
    }

    private func marker(model: String, tokenizer: String) -> Data {
        Data(#"{"modelRevision":"\#(model)","tokenizerRevision":"\#(tokenizer)"}"#.utf8)
    }

    /// Lays out what a finished download leaves behind.
    private func finishInstall(_ store: LanguageDetectionModelStore, marker: Data? = nil) async throws {
        let layout = await store.layout()
        let manager = FileManager.default
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try manager.createDirectory(at: layout.model.appendingPathComponent("\(name).mlmodelc"), withIntermediateDirectories: true)
        }
        try manager.createDirectory(at: layout.tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: layout.tokenizer.appendingPathComponent("tokenizer.json"))
        let release = LanguageDetectionModelStore.Release.current
        try (marker ?? self.marker(model: release.modelRevision, tokenizer: release.tokenizerRevision)).write(to: layout.marker)
    }

    @Test func nothingIsInstalledAtFirst() async {
        let (store, _) = makeStore()
        #expect(await !store.isInstalled())
        #expect(await store.installedFolders() == nil)
        #expect(await store.status() == .notInstalled)
    }

    @Test func aFinishedInstallIsFoundWithItsFolders() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await finishInstall(store)
        #expect(await store.isInstalled())
        #expect(await store.status() == .installed)
        let folders = await store.installedFolders()
        #expect(folders?.model.lastPathComponent == "openai_whisper-base")
        #expect(folders?.tokenizerBase.path.hasPrefix(root.path) == true)
    }

    @Test func aDownloadWithoutTheMarkerNeverCounts() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await finishInstall(store)
        try FileManager.default.removeItem(at: await store.layout().marker)
        #expect(await !store.isInstalled())
    }

    @Test func aMissingModelFileMeansNotInstalled() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await finishInstall(store)
        try FileManager.default.removeItem(at: await store.layout().model.appendingPathComponent("TextDecoder.mlmodelc"))
        #expect(await !store.isInstalled())
    }

    @Test func aMissingTokenizerMeansNotInstalled() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await finishInstall(store)
        try FileManager.default.removeItem(at: await store.layout().tokenizer.appendingPathComponent("tokenizer.json"))
        #expect(await !store.isInstalled())
    }

    @Test func filesFromOtherPinnedRevisionsDoNotCount() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = LanguageDetectionModelStore.Release.current
        try await finishInstall(store, marker: marker(model: "older-model-revision", tokenizer: release.tokenizerRevision))
        #expect(await !store.isInstalled())
        try await finishInstall(store, marker: marker(model: release.modelRevision, tokenizer: "older-tokenizer-revision"))
        #expect(await !store.isInstalled())
    }

    @Test func removingDeletesTheFilesAndTheStateFollows() async throws {
        let (store, root) = makeStore()
        try await finishInstall(store)
        #expect(await store.isInstalled())
        await store.remove()
        #expect(await !store.isInstalled())
        #expect(await store.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func installingWhenAlreadyInstalledReportsDoneWithoutDownloading() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await finishInstall(store)
        let reported = Reported()
        try await store.install { reported.add($0) }
        #expect(reported.values == [1])
    }

    @Test func theInstallFolderIsNamedAfterThePinnedRevisions() {
        let release = LanguageDetectionModelStore.Release.current
        #expect(release.directoryName == "0f63a780-e37978b9")
        #expect(release.modelRevision.count == 40)
        #expect(release.tokenizerRevision.count == 40)
    }
}

// MARK: - Install behaviour, with a fake installer instead of a download

@Suite(.timeLimit(.minutes(1)))
struct LanguageDetectionModelStoreInstallTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
    }

    /// What a finished download leaves in the install folder.
    private static func writeFiles(_ base: URL, _ release: LanguageDetectionModelStore.Release) throws {
        let manager = FileManager.default
        let model = base.appendingPathComponent("models/\(release.modelRepo)/\(release.modelFolderName)", isDirectory: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try manager.createDirectory(at: model.appendingPathComponent("\(name).mlmodelc"), withIntermediateDirectories: true)
        }
        let tokenizer = base.appendingPathComponent("models/\(release.tokenizerRepo)", isDirectory: true)
        try manager.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
    }

    /// Lets a test hold an install open and see how many installs really ran. With `obeysCancellation`
    /// false the fake installer behaves like Core ML preparation, which cannot be interrupted.
    private actor Control {
        private(set) var runs = 0
        private var open: Bool
        private let obeysCancellation: Bool
        init(open: Bool = false, obeysCancellation: Bool = true) {
            self.open = open
            self.obeysCancellation = obeysCancellation
        }
        func begin() { runs += 1 }
        func release() { open = true }
        func waitUntilReleased() async throws {
            while !open {
                if obeysCancellation { try await Task.sleep(for: .milliseconds(5)) }
                else { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        func waitUntilRuns(_ count: Int) async throws {
            while runs < count { try await Task.sleep(for: .milliseconds(5)) }
        }
    }

    private func store(root: URL, control: Control, fail: Bool = false) -> LanguageDetectionModelStore {
        LanguageDetectionModelStore(root: root) { base, release, report in
            await control.begin()
            report(0.4)
            try await control.waitUntilReleased()
            if fail { throw LanguageDetectionModelError.incompleteDownload }
            try Self.writeFiles(base, release)
            report(0.9)
        }
    }

    private func waitUntilInstalled(_ store: LanguageDetectionModelStore) async throws -> Bool {
        for _ in 0..<400 {
            if await store.isInstalled() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitUntilDownloading(_ store: LanguageDetectionModelStore, atLeast fraction: Double) async throws {
        for _ in 0..<400 {
            if case .downloading(let progress?) = await store.status(), progress >= fraction { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the install never reached \(fraction)")
    }

    @Test func aSecondCallerJoinsTheRunningInstallAndBothSeeItFinish() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = Control()
        let store = store(root: root, control: control)
        let first = Reported(), second = Reported()

        let a = Task { try await store.install { first.add($0) } }
        try await control.waitUntilRuns(1)
        try await waitUntilDownloading(store, atLeast: 0.4)
        // The second caller arrives while the first install is running, so it can only be joining it.
        let b = Task { try await store.install { second.add($0) } }
        try await Task.sleep(for: .milliseconds(30))
        await control.release()
        try await a.value
        try await b.value

        #expect(await control.runs == 1)
        #expect(await store.isInstalled())
        #expect(await store.status() == .installed)
        #expect(first.values.contains(0.4) && first.values.last == 1)
        // The late joiner was told where the install stood when it arrived, and then saw the end.
        #expect(second.values.first == 0.4 && second.values.last == 1)
    }

    @Test func aCancelledCallerStopsWaitingAtOnceButTheInstallFinishes() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = Control()
        let store = store(root: root, control: control)

        let waiting = Task { try await store.install { _ in } }
        try await control.waitUntilRuns(1)
        waiting.cancel()
        do {
            try await waiting.value
            Issue.record("the cancelled caller should have thrown")
        } catch is CancellationError {}

        // The download itself carries on, and a new caller joins it instead of starting another.
        if case .downloading = await store.status() {} else { Issue.record("expected the install to still be running") }
        await control.release()
        try await store.install { _ in }
        #expect(await control.runs == 1)
        #expect(try await waitUntilInstalled(store))
    }

    @Test func aCallerCancelledBeforeItStartsNeverHangs() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = Control()
        let store = store(root: root, control: control)

        let task = Task {
            // Already cancelled by the time the install call is made.
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.install { _ in }
        }
        do {
            try await task.value
            Issue.record("expected a cancellation")
        } catch is CancellationError {}
        await control.release()
        #expect(try await waitUntilInstalled(store))
    }

    @Test func removingDuringAnInstallEndsTheWaitersAndLeavesNoFiles() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = Control()
        let store = store(root: root, control: control)

        let waiting = Task { try await store.install { _ in } }
        try await control.waitUntilRuns(1)
        await store.remove()
        do {
            try await waiting.value
            Issue.record("removing should end the wait with a cancellation")
        } catch is CancellationError {}
        #expect(await store.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        await control.release()
        try await store.install { _ in }
        #expect(await store.isInstalled())
    }

    @Test func anInstallAskedForWhileARemovalIsFinishingWaitsForIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The first install ignores cancellation, like Core ML preparation, so the removal has to wait for it.
        let control = Control(obeysCancellation: false)
        let store = store(root: root, control: control)

        let first = Task { try await store.install { _ in } }
        try await control.waitUntilRuns(1)
        let removing = Task { await store.remove() }
        try await Task.sleep(for: .milliseconds(30))
        // The removal is still waiting for the first install, and now the viewer asks to install again.
        let second = Task { try await store.install { _ in } }
        try await Task.sleep(for: .milliseconds(30))
        await control.release()
        await removing.value
        do { try await first.value; Issue.record("the first caller should have been cancelled") } catch is CancellationError {}
        try await second.value

        // The new install ran after the removal and its files were not deleted by it.
        #expect(await control.runs == 2)
        #expect(await store.isInstalled())
        #expect(await store.status() == .installed)
    }

    @Test func aFailedInstallReportsTheErrorAndALaterOneWorks() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = Control(open: true)
        let failing = store(root: root, control: control, fail: true)
        do {
            try await failing.install { _ in }
            Issue.record("expected the install to fail")
        } catch let error as LanguageDetectionModelError {
            #expect(error == .incompleteDownload)
        }
        #expect(await failing.status() == .notInstalled)

        let working = store(root: root, control: control)
        try await working.install { _ in }
        #expect(await working.isInstalled())
    }

    @Test func installingExcludesTheFolderFromBackupsAndClearsOlderReleases() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appendingPathComponent("11111111-22222222", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: older.appendingPathComponent("weights.bin"))
        let store = store(root: root, control: Control(open: true))

        try await store.install { _ in }

        #expect(!FileManager.default.fileExists(atPath: older.path))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(await store.isInstalled())
    }

    @Test func aStaleMarkerFromAnInterruptedRemovalDoesNotMakeAHalfDownloadedFolderCount() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A marker survived but the model files did not.
        let control = Control()
        let store = store(root: root, control: control)
        let release = LanguageDetectionModelStore.Release.current
        let layout = await store.layout()
        try FileManager.default.createDirectory(at: layout.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"modelRevision":"\#(release.modelRevision)","tokenizerRevision":"\#(release.tokenizerRevision)"}"#.utf8).write(to: layout.marker)
        #expect(await !store.isInstalled())

        let install = Task { try await store.install { _ in } }
        try await control.waitUntilRuns(1)
        // Starting an install clears the stale marker first, so "marker present" means "finished".
        #expect(!FileManager.default.fileExists(atPath: layout.marker.path))
        await control.release()
        try await install.value
        #expect(await store.isInstalled())
    }
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
