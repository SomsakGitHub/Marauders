//
//  FirebaseRemoteConfigSource.swift
//  Marauders
//

import FirebaseCore
import FirebaseRemoteConfig
import Foundation
import Synchronization

/// The two numbers of the force-update gate, read from Firebase Remote Config (docs/adr/012-force-update.md). The only
/// file of the app that imports Firebase: everything else sees the two published texts as `RemoteConfigValues`.
///
/// Nothing starts at launch. The SDK is started by the first `fetch()`, which `MaraudersApp` makes only after the pass
/// check, and never in a UI test (the UITEST composition does not build this type). `fetch()` is `@concurrent`, so the
/// plist read, the check of it and the wait for the network run off the main actor. The one call that starts the SDK is
/// made on the main actor, because the SDK's header asks for that (`FIRApp.h`: "This method should be called from the
/// main thread") and it is the one call whose failure Swift cannot catch; it is made once per launch.
///
/// The SDK is started only from a plist that `FirebasePlistCheck` accepts, because it raises an Objective-C exception,
/// which Swift cannot catch, for a missing plist or a key it cannot start from. Without a usable plist this logs one line
/// per ask and answers nil, so the gate stays open and the app runs as it did before the gate existed. Whether the SDK
/// is started is kept here and never asked of the SDK, which logs an error line for every "no": that would be the normal
/// answer on a Run without a plist and at the first ask of every launch.
///
/// Every other failure also answers nil, after a line that says only the error's domain and code: a fetch that failed
/// or timed out, the SDK's own rate limit. Nothing here logs a plist value.
struct FirebaseRemoteConfigSource: RemoteConfigSource {
    /// The names of the two parameters in the Firebase console.
    nonisolated static let minimumBuildKey = "minimum_build"
    nonisolated static let updateURLKey = "update_url"

    /// Whether this process has started the SDK. The SDK raises when it is started twice, so the check and the start are
    /// made under this lock: two asks at once start it once.
    private nonisolated static let sdkStarted = Mutex(false)

    /// Starts nothing: the SDK waits for the first `fetch()`.
    init() {}

    @concurrent
    func fetch() async -> RemoteConfigValues? {
        guard await startFirebaseIfNeeded() else {
            return nil
        }
        let remoteConfig = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        // One real fetch an hour at most, however often the app opens (the SDK's own default is 12 hours, too slow for
        // a raise to reach anyone); 10 seconds, not 60, before a hung fetch frees the gate's one in-flight slot.
        settings.minimumFetchInterval = 3600
        settings.fetchTimeout = 10
        remoteConfig.configSettings = settings
        let askedBefore: Date?
        do {
            try await remoteConfig.ensureInitialized()
            // Inside the hour the SDK answers from the values it saved and asks Google nothing, and both ways end in a
            // success. Only its "last fetch" time, which moves when Google answered, says which this was: read before
            // and after, it becomes the origin the log shows.
            askedBefore = remoteConfig.lastFetchTime
            switch try await remoteConfig.fetchAndActivate() {
            case .successFetchedFromRemote, .successUsingPreFetchedData:
                break
            case .error:
                await AppLog.warning("update", "firebase fetch failed: status error")
                return nil
            @unknown default:
                await AppLog.warning("update", "firebase fetch failed: unknown status")
                return nil
            }
        } catch {
            let failure = error as NSError
            await AppLog.warning("update", "firebase fetch failed: \(failure.domain) \(failure.code)")
            return nil
        }
        return RemoteConfigValues(
            minimumBuild: remoteConfig.configValue(forKey: Self.minimumBuildKey).stringValue,
            updateURL: remoteConfig.configValue(forKey: Self.updateURLKey).stringValue,
            origin: RemoteConfigOrigin.judge(lastFetchBefore: askedBefore, lastFetchAfter: remoteConfig.lastFetchTime))
    }

    /// True when the SDK is running (it already was, or it was started now); false, after a line in the log, when it
    /// cannot be started from this build's plist.
    private nonisolated func startFirebaseIfNeeded() async -> Bool {
        if Self.sdkStarted.withLock({ $0 }) {
            return true
        }
        // Read and judged here, off the main actor: a plist that the SDK would raise on never reaches it.
        let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")
        if let problem = FirebasePlistCheck.problem(in: FirebasePlistCheck.plist(atPath: path)) {
            await AppLog.warning("update", "firebase not started: \(problem); the gate stays open")
            return false
        }
        // That one call, and nothing else, is made on the main actor (the SDK's header asks for it).
        let started = await MainActor.run { Self.startSDK(plistPath: path) }
        if !started {
            await AppLog.warning("update", "firebase not started: the SDK cannot read the plist; the gate stays open")
        }
        return started
    }

    /// Starts the SDK from the plist at `plistPath`, once per process (a second start raises), and says whether it is
    /// running. On the main actor.
    private static func startSDK(plistPath: String?) -> Bool {
        sdkStarted.withLock { started -> Bool in
            if started {
                return true
            }
            guard let plistPath, let options = FirebaseOptions(contentsOfFile: plistPath) else {
                return false
            }
            FirebaseApp.configure(options: options)
            started = true
            return true
        }
    }
}
