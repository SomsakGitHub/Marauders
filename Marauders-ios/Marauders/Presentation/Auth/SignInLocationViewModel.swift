import CoreLocation
import MapKit
import Foundation
import Observation

@MainActor
@Observable
final class SignInLocationViewModel {
    private(set) var countryCode: String?
    private(set) var isResolving = false
    private(set) var message: String?
    private(set) var authorizationStatus: CLAuthorizationStatus
    private let manager: any LocationManaging
    private let bridge = LocationManagerDelegateBridge()
    private let resolveCountry: (CLLocation) async throws -> String?
    private var generation = 0
    private var hasRequestedAlways = false
    private var lookup: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private let useUITestState: Bool
    var canSignIn: Bool {
        (authorizationStatus == .authorizedAlways) && countryCode != nil && !isResolving
    }
    var needsSettings: Bool { authorizationStatus == .denied || authorizationStatus == .restricted || (authorizationStatus == .authorizedWhenInUse && hasRequestedAlways) }

    init(manager: any LocationManaging = CLLocationManager(), useUITestState: Bool = AppRuntimeConfiguration.isUITesting,
         resolveCountry: @escaping (CLLocation) async throws -> String? = { location in
             guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
             return try await request.mapItems.first?.addressRepresentations?.region?.identifier
         }) {
        self.manager = manager
        self.useUITestState = useUITestState
        self.resolveCountry = resolveCountry
        authorizationStatus = manager.authorizationStatus
        if useUITestState {
            let denied = ProcessInfo.processInfo.arguments.contains("UITEST_LOCATION_DENIED")
            authorizationStatus = denied ? .denied : .authorizedAlways
            countryCode = denied ? nil : "TH"
            message = denied ? "Set location access to Always in Settings before signing in." : nil
        }
    }

    func begin() {
        guard !useUITestState else { return }
        bridge.onAuthorizationChange = { [weak self] in self?.refresh() }
        bridge.onLocations = { [weak self] locations in self?.receive(locations) }
        bridge.onFailure = { [weak self] _ in self?.fail("Could not get your location. Please try again.") }
        manager.delegate = bridge
        refresh()
    }
    func refresh() {
        guard !useUITestState else { return }
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            countryCode = nil
            message = "Allow location access, then select Always before signing in."
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            fail("Set location access to Always in Settings before signing in.")
            if !hasRequestedAlways {
                hasRequestedAlways = true
                manager.requestAlwaysAuthorization()
            }
        case .authorizedAlways:
            guard countryCode == nil, !isResolving else { return }
            isResolving = true
            message = "Finding your country…"
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            manager.requestLocation()
            timeout?.cancel()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.fail("Could not identify your country. Check your connection and try again.")
            }
        default:
            fail("Set location access to Always in Settings before signing in.")
        }
    }
    func stop() {
        generation += 1
        lookup?.cancel()
        timeout?.cancel()
        manager.delegate = nil
        isResolving = false
    }
    private func fail(_ text: String) {
        generation += 1
        lookup?.cancel()
        timeout?.cancel()
        countryCode = nil
        isResolving = false
        message = text
    }
    private func receive(_ locations: [CLLocation]) {
        guard authorizationStatus == .authorizedAlways,
              let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 120 else {
            fail("Could not get a recent location. Please try again.")
            return
        }
        generation += 1
        let request = generation
        lookup?.cancel()
        lookup = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await resolveCountry(location)?.uppercased()
                guard !Task.isCancelled, generation == request else { return }
                guard let code, code.count == 2, Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else {
                    fail("Could not identify your country. Please try again.")
                    return
                }
                authorizationStatus = manager.authorizationStatus
                guard authorizationStatus == .authorizedAlways else {
                    fail("Set location access to Always in Settings before signing in.")
                    return
                }
                timeout?.cancel()
                countryCode = code
                isResolving = false
                message = nil
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                fail("Could not identify your country. Check your connection and try again.")
            }
        }
    }
}
