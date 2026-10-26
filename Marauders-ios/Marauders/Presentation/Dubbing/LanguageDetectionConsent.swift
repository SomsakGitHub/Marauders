//
//  LanguageDetectionConsent.swift
//  Marauders
//

import Foundation
import Observation

/// Remembers, for this run of the app, that the viewer said "Not now" to downloading the language
/// detection model, so every unknown clip does not ask again. It is deliberately not saved: the question
/// comes back the next time the app starts.
///
/// Agreeing is not stored anywhere. It travels with the one `prepare` call that follows the tap, so an
/// agreement that never led to a download (the viewer left, the app went to the background) cannot
/// start a download later on a different clip.
@MainActor
@Observable
final class LanguageDetectionConsent {
    static let shared = LanguageDetectionConsent()

    private(set) var declined = false

    func decline() { declined = true }
}
