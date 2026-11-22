//
//  UpdateGateComposition.swift
//  Marauders
//

import Foundation

/// Builds the force-update gate (docs/adr/012-force-update.md). A static factory, not a part of
/// `AppDependencyContainer`, because `MaraudersApp` needs the gate before `AppRootView` creates that container: the
/// window decides there whether to show the Update screen in place of the app.
///
/// The gate reads Firebase Remote Config through `FirebaseRemoteConfigSource`. Building the gate starts nothing and
/// asks nothing: the SDK starts at the first `refreshIfDue()`, which `MaraudersApp` makes only after the pass check.
/// A failed ask is not worth a retry here (the next foreground asks again).
@MainActor
enum UpdateGateComposition {
    /// - Parameters:
    ///   - defaults: Where the last good answer is kept.
    ///   - source: Where a fresh answer comes from. Nil is the real one, `FirebaseRemoteConfigSource`; a test passes a
    ///     fake, so that nothing starts the SDK or reaches the network.
    ///   - currentBuild: This build's number: nil when it cannot be read, which never stops anyone.
    ///   - isDebugBuild: A debug build is never stopped.
    ///
    /// Under `UITEST` all four are ignored: the gate answers from `UITestAppConfigRepository`, which says "update
    /// required" or "no gate" only for the launch arguments of `UITestUpdateScenario`, and uses build 2 and a
    /// non-debug build so that the debug exemption never hides the screen. Nothing touches Firebase or the network
    /// in that mode, and `FirebaseRemoteConfigSource` is not even built.
    static func makeViewModel(
        defaults: UserDefaults = .standard,
        source: (any RemoteConfigSource)? = nil,
        currentBuild: Int? = BuildNumber.current,
        isDebugBuild: Bool = BuildNumber.isDebugBuild
    ) -> UpdateGateViewModel {
        let repository: AppConfigRepository
        let build: Int?
        let debug: Bool
        if AppRuntimeConfiguration.isUITesting {
            repository = UITestAppConfigRepository(scenario: AppRuntimeConfiguration.uiTestUpdateScenario)
            build = 2
            debug = false
        } else {
            repository = FirebaseAppConfigRepository(source: source ?? FirebaseRemoteConfigSource(), defaults: defaults)
            build = currentBuild
            debug = isDebugBuild
        }
        AppLog.info("update", "gate: build=\(build.map(String.init) ?? "?") debug=\(debug)")
        return UpdateGateViewModel(
            check: CheckUpdateRequirementUseCase(repository: repository, currentBuild: build, isDebugBuild: debug))
    }
}
