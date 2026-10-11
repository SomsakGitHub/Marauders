//
//  Country.swift
//  Marauders
//

import Foundation

/// A country the user can associate with their account (ISO 3166-1 alpha-2).
struct Country: Identifiable, Hashable, Sendable {
    /// Uppercase ISO 3166-1 alpha-2 code, e.g. `"TH"`.
    let code: String
    /// Localized display name, e.g. `"Thailand"`.
    let name: String

    var id: String { code }

    /// Regional indicator flag emoji derived from the ISO code, e.g. `"🇹🇭"`.
    var flagEmoji: String { Country.flagEmoji(for: code) }

    static func flagEmoji(for code: String) -> String {
        code.uppercased().unicodeScalars.reduce(into: String()) { result, scalar in
            if let indicator = UnicodeScalar(0x1F1E6 - 0x41 + scalar.value) {
                result.unicodeScalars.append(indicator)
            }
        }
    }
}

enum CountryCatalog {
    /// All selectable countries, sorted by localized name.
    static func all(locale: Locale = .current) -> [Country] {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter(isISOCountryCode)
            .compactMap { code in
                guard let name = locale.localizedString(forRegionCode: code) else { return nil }
                return Country(code: code.uppercased(), name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The device region, so the picker opens on a sensible default.
    static func defaultCode(locale: Locale = .current) -> String {
        guard let region = locale.region?.identifier, isISOCountryCode(region) else {
            return "US"
        }
        return region.uppercased()
    }

    static func name(for code: String, locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }

    private static func isISOCountryCode(_ code: String) -> Bool {
        code.count == 2 && code.allSatisfy(\.isLetter)
    }
}
