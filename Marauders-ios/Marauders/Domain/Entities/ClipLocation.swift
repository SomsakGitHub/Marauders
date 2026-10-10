//
//  ClipLocation.swift
//  Marauders
//

import Foundation

struct ClipLocation: Sendable, Equatable {
    let latitude: Double
    let longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard Self.isValid(latitude: latitude, longitude: longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        return (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
    }
}
