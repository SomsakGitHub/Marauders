//
//  ListeningLanguageAvailability.swift
//  Marauders
//

import Foundation

/// Which listening languages this iPhone cannot serve (no speech voice or no translation route).
protocol ListeningLanguageAvailability {
    func unavailableLanguageCodes() async -> Set<String>
}

struct NoopListeningLanguageAvailability: ListeningLanguageAvailability {
    func unavailableLanguageCodes() async -> Set<String> { [] }
}
