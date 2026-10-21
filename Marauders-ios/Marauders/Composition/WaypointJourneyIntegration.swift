//
//  WaypointJourneyIntegration.swift
//  Marauders
//

import SwiftUI
import WaypointJourney

/// Thin adapter around the WaypointSDK's `WaypointJourney` flow so views don't
/// depend on the package directly.
enum WaypointJourneyIntegration {
    /// SwiftUI host view for the SDK's 3-step flow. Call `onComplete` when the
    /// user taps "Back to app".
    @MainActor
    static func makeFlowView(onComplete: @escaping () -> Void) -> some View {
        WaypointJourneySDK.makeFlowView(onComplete: onComplete)
    }
}
