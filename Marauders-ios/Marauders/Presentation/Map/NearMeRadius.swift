//
//  NearMeRadius.swift
//  Marauders
//

import CoreLocation
import Foundation

enum NearMeRadius: Int, CaseIterable, Identifiable, Hashable {
    case fiveKm = 5
    case twentyFiveKm = 25
    case fiftyKm = 50

    var id: Int { rawValue }

    static let `default` = NearMeRadius.twentyFiveKm

    var kilometers: Int { rawValue }

    var meters: CLLocationDistance {
        CLLocationDistance(kilometers) * 1_000
    }

    var label: String { "\(kilometers) km" }

    var emptyClipsMessage: String { "No clips within \(kilometers) km" }
}
