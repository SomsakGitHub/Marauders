//
//  BackgroundLocationMonitor.swift
//  Marauders
//

import CoreLocation
import Foundation
import Observation
import UIKit

/// Sends the viewer's location while Marauders is closed, so the mutual followers they share it with see where they
/// are without waiting for them to open the app. It uses the two location services that cost the least battery: iOS
/// wakes the app, or launches it again in the background, once the iPhone has moved about 500 m, and when it arrives
/// somewhere it stays. Both need Always location access, and run only while the viewer shares.
///
/// Whether the viewer shares is kept on the iPhone as the Worker last said it, because a launch in the background comes
/// before anything can ask the Worker; each report's answer corrects it, so sharing turned off on another device stops
/// this one at its next move. `ForegroundLocationReporter` still sends while the app is in use.
@MainActor
@Observable
final class BackgroundLocationMonitor {
    /// A fix older than this says where the viewer was, not where they are.
    static let maximumFixAge: TimeInterval = 10 * 60
    static let sharingKey = "locationSharing.sendsWhileClosed"

    /// Whether iOS lets the app have the location while it is closed. Without it mutual followers see where the viewer
    /// last used the app.
    private(set) var isAlwaysAuthorized: Bool

    @ObservationIgnored private let locationManager: BackgroundLocationManaging
    @ObservationIgnored private let delegateBridge = LocationManagerDelegateBridge()
    @ObservationIgnored private let report: ReportUserLocationUseCase
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let holdAwake: @MainActor (String) -> @MainActor () -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isProtectedDataAvailable: () -> Bool
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var protectedDataObserver: NSObjectProtocol?
    @ObservationIgnored private var isSharing: Bool
    @ObservationIgnored private var isMonitoring = false
    @ObservationIgnored private var isAttached = false
    /// Bumped each time sharing stops: a report that was out then must not stop a sharing turned on again since.
    @ObservationIgnored private var generation = 0

    init(
        locationManager: BackgroundLocationManaging = CLLocationManager(),
        report: ReportUserLocationUseCase,
        defaults: UserDefaults = .standard,
        holdAwake: @escaping @MainActor (String) -> @MainActor () -> Void = BackgroundLocationMonitor
            .beginBackgroundTask,
        now: @escaping () -> Date = Date.init,
        isProtectedDataAvailable: @escaping () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
        notificationCenter: NotificationCenter = .default
    ) {
        self.locationManager = locationManager
        self.report = report
        self.defaults = defaults
        self.holdAwake = holdAwake
        self.now = now
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.notificationCenter = notificationCenter
        isSharing = defaults.bool(forKey: Self.sharingKey)
        isAlwaysAuthorized = locationManager.authorizationStatus == .authorizedAlways
    }

    /// Starts the services again at launch. A launch in the background for a location gets it this way too: iOS hands
    /// the waiting event to the location manager that starts them.
    func resume() {
        // Before the first unlock after a restart the saved choice cannot be read and looks unset; read as off it would
        // stop the services for good, so they are left as they are until the unlock. Once the iPhone has been unlocked
        // the choice (and the session) read fine while it is locked again, which is when most moves come.
        guard defaults.object(forKey: Self.sharingKey) != nil || isProtectedDataAvailable() else {
            waitForProtectedData()
            return
        }
        isSharing = defaults.bool(forKey: Self.sharingKey)
        if !isSharing {
            // Nothing should be running, but a service left on would keep waking the app for nothing.
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
        }
        update()
    }

    /// Follows whether the viewer shares, as the Worker last said it; false after a sign-out.
    func setSharing(_ sharing: Bool) {
        if sharing != isSharing {
            isSharing = sharing
            defaults.set(sharing, forKey: Self.sharingKey)
        }
        if !sharing { generation += 1 }
        update()
    }

    private func waitForProtectedData() {
        guard protectedDataObserver == nil else { return }
        AppLog.info("location", "sharing while closed waits for the first unlock")
        protectedDataObserver = notificationCenter.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.protectedDataBecameAvailable() }
        }
    }

    private func protectedDataBecameAvailable() {
        if let protectedDataObserver { notificationCenter.removeObserver(protectedDataObserver) }
        protectedDataObserver = nil
        resume()
    }

    private func update() {
        if isSharing { attachIfNeeded() }
        let isAlways = locationManager.authorizationStatus == .authorizedAlways
        if isAlwaysAuthorized != isAlways { isAlwaysAuthorized = isAlways }
        let shouldMonitor = isSharing && isAlways
        guard shouldMonitor != isMonitoring else { return }
        isMonitoring = shouldMonitor
        if shouldMonitor {
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.startMonitoringVisits()
            AppLog.info("location", "sharing while closed started")
        } else {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            AppLog.info("location", "sharing while closed stopped")
        }
    }

    private func attachIfNeeded() {
        guard !isAttached else { return }
        isAttached = true
        delegateBridge.onAuthorizationChange = { [weak self] in
            // Always turned on in Settings starts the services; anything less stops them.
            self?.update()
        }
        delegateBridge.onLocations = { [weak self] locations in
            self?.handle(locations)
        }
        delegateBridge.onVisit = { [weak self] visit in
            self?.handle(visit)
        }
        delegateBridge.onFailure = { error in
            AppLog.warning("location", "sharing while closed failed: \(error.localizedDescription)")
        }
        locationManager.delegate = delegateBridge
    }

    private func handle(_ locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
            now().timeIntervalSince(fix.timestamp) <= Self.maximumFixAge
        else { return }
        send(fix.coordinate)
    }

    /// An arrival says where the viewer is now. A departure says where they were, and moving on reports anyway.
    private func handle(_ visit: CLVisit) {
        guard visit.departureDate == .distantFuture, visit.horizontalAccuracy >= 0 else { return }
        send(visit.coordinate)
    }

    private func send(_ coordinate: CLLocationCoordinate2D) {
        // A service that was just stopped can still hand over an event it had.
        guard isMonitoring,
            let location = ClipLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        else { return }
        let generation = generation
        let release = holdAwake("Share location")
        Task {
            defer { release() }
            do {
                let stillShares = try await report.executeWhileClosed(location: location)
                AppLog.info("location", "location reported while closed")
                // Turned off on another device: the Worker kept nothing, and nothing more goes out.
                if stillShares == false, generation == self.generation { setSharing(false) }
            } catch {
                AppLog.warning("location", "report while closed failed: \(error.localizedDescription)")
                // Signed out, or the session is no longer good: stop until the Worker says the viewer shares again.
                guard generation == self.generation, Self.endsSession(error) else { return }
                setSharing(false)
            }
        }
    }

    private static func endsSession(_ error: Error) -> Bool {
        switch error as? UserLocationAPIError {
        case .notAuthenticated, .serverError(401):
            return true
        default:
            return false
        }
    }

    /// Keeps the app running until a report is through, since iOS gives an app it woke for a location only a few
    /// seconds. Answers how to let it go.
    static func beginBackgroundTask(_ name: String) -> @MainActor () -> Void {
        let task = BackgroundTask(name: name)
        return { task.end() }
    }
}

@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
