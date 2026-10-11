//
//  AVAssetVideoLocationReader.swift
//  Marauders
//

import AVFoundation
import Foundation

/// Reads the ISO 6709 location string that Apple writes into captured videos
/// (`com.apple.quicktime.location.ISO6709`), e.g. `+13.7563+100.5018+010.000/`.
struct AVAssetVideoLocationReader: VideoLocationReading {
    func location(fromVideoAt url: URL) async -> ClipLocation? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }

        for item in metadata {
            guard let identifier = item.identifier else { continue }
            let isLocationItem = identifier == .quickTimeMetadataLocationISO6709
                || identifier == .commonIdentifierLocation
            guard isLocationItem else { continue }

            guard let value = try? await item.load(.stringValue),
                  let location = Self.parseISO6709(value)
            else { continue }

            AppLog.info("upload", "read clip location from video metadata")
            return location
        }

        return nil
    }

    /// Parses the first two signed decimal-degree components of an ISO 6709 string.
    /// Returns `nil` for formats that are not decimal degrees (e.g. DDMM.MMMM),
    /// so callers fall back to a manual pick instead of showing wrong coordinates.
    static func parseISO6709(_ raw: String) -> ClipLocation? {
        var numbers: [Double] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                numbers.append(Double(current) ?? .nan)
                current = ""
            }
        }

        for character in raw {
            switch character {
            case "+", "-":
                flush()
                current.append(character)
            case "0"..."9", ".":
                current.append(character)
            default:
                flush()
            }
        }
        flush()

        guard numbers.count >= 2 else { return nil }
        let latitude = numbers[0]
        let longitude = numbers[1]
        guard latitude.isFinite, longitude.isFinite,
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }

        return ClipLocation(latitude: latitude, longitude: longitude)
    }
}
