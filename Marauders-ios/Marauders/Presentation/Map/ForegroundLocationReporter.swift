//
//  ForegroundLocationReporter.swift
//  Marauders
//

import CoreLocation
import Foundation

/// Sends the viewer's location while the app is in use, so the mutual followers they share it with see where they are.
/// It reports only when asked (the app coming to the foreground, then a timer while it stays there) and at most once
/// per `interval`. It never runs in the background and never asks for a permission the viewer has not given.
@MainActor
final class ForegroundLocationReporter {
    static let interval: TimeInterval = 5 * 60
    /// A timer firing a little early still counts as on time, or reports would go out every other tick.
    static let timerSlack: TimeInterval = 10
    /// A fix that has not arrived by then is given up on, so the next chance can ask again.
    static let fixTimeout: TimeInterval = 60

    /// Asked when a fix arrives: false (the viewer stopped sharing meanwhile) drops it unsent.
    var shouldSend: () -> Bool = { true }
    /// Called after a location went out.
    var onReported: () -> Void = {}

    private let locationManager: LocationManaging
    private let delegateBridge = LocationManagerDelegateBridge()
    private let report: ReportUserLocationUseCase
    private let now: () -> Date
    /// When the last fix was asked for; the next is due `interval` after it.
    private var lastRequestAt: Date?
    private var pendingSince: Date?
    /// Bumped by `reset()`: a fix asked for before then belongs to a session or a choice that is over.
    private var generation = 0
    private var pendingGeneration: Int?
    private var isAttached = false

    init(
        locationManager: LocationManaging = CLLocationManager(),
        report: ReportUserLocationUseCase,
        now: @escaping () -> Date = Date.init
    ) {
        self.locationManager = locationManager
        self.report = report
        self.now = now
    }

    /// Asks for a fix and sends it, unless one was asked for within `interval`; `force` skips that wait, as when the
    /// viewer has just turned sharing on.
    func reportIfDue(force: Bool = false) {
        guard isAuthorized else { return }
        let now = now()
        if let pendingSince, now.timeIntervalSince(pendingSince) < Self.fixTimeout { return }
        if !force, let lastRequestAt, now.timeIntervalSince(lastRequestAt) < Self.interval - Self.timerSlack { return }
        attachIfNeeded()
        lastRequestAt = now
        pendingSince = now
        pendingGeneration = generation
        locationManager.requestLocation()
    }

    /// Forgets the last report and drops a fix still on its way, so nothing asked for before goes out: after the
    /// session ends, or the viewer stops sharing.
    func reset() {
        generation += 1
        lastRequestAt = nil
        pendingSince = nil
        pendingGeneration = nil
    }

    private var isAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    private func attachIfNeeded() {
        guard !isAttached else { return }
        isAttached = true
        delegateBridge.onLocations = { [weak self] locations in
            self?.send(locations)
        }
        delegateBridge.onFailure = { [weak self] error in
            guard let self else { return }
            // The next chance asks again rather than waiting out the interval.
            if pendingGeneration == generation { lastRequestAt = nil }
            pendingSince = nil
            pendingGeneration = nil
            AppLog.warning("location", "sharing fix failed: \(error.localizedDescription)")
        }
        locationManager.delegate = delegateBridge
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func send(_ locations: [CLLocation]) {
        let current = pendingGeneration == generation
        pendingSince = nil
        pendingGeneration = nil
        guard current, shouldSend(),
            let coordinate = locations.last?.coordinate,
            let location = ClipLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        else { return }
        let generation = generation
        Task {
            do {
                try await report.execute(location: location)
                guard generation == self.generation else { return }
                AppLog.info("location", "shared location reported")
                onReported()
            } catch {
                // The next chance tries again, unless the session or the choice changed meanwhile.
                if generation == self.generation { lastRequestAt = nil }
                AppLog.warning("location", "sharing report failed: \(error.localizedDescription)")
            }
        }
    }
}
