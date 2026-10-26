//
//  LanguageModelManaging.swift
//  Marauders
//

import Foundation

/// Reads and changes Apple-managed speech assets. Translation downloads need a SwiftUI
/// `TranslationSession`, so the view model drives those through the view instead.
protocol LanguageModelManaging {
    /// Returns `.installed`, `.notInstalled` or `.unsupported`.
    func status(of model: LanguageModel) async -> LanguageModelStatus
    func installSpeechModel(locale: String, progress: @escaping @MainActor (Double) -> Void) async throws
    @discardableResult
    func removeSpeechModel(locale: String) async -> Bool
    func installDetectionModel(progress: @escaping @MainActor (Double) -> Void) async throws
    func removeDetectionModel() async
}

struct NoopLanguageModelManager: LanguageModelManaging {
    func status(of model: LanguageModel) async -> LanguageModelStatus { .unsupported }
    func installSpeechModel(locale: String, progress: @escaping @MainActor (Double) -> Void) async throws {}
    func removeSpeechModel(locale: String) async -> Bool { false }
    func installDetectionModel(progress: @escaping @MainActor (Double) -> Void) async throws {}
    func removeDetectionModel() async {}
}
