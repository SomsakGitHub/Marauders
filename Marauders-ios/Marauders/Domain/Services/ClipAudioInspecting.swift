import Foundation

nonisolated struct ClipAudioAssessment: Sendable, Equatable, Codable, Hashable {
    enum Signal: String, Sendable, Codable { case detected, noTrack, quietSamples, unknown }
    enum Content: String, Sendable, Codable { case speech, music, mixed, unknown }
    var content: Content = .unknown
    var speechConfidence: Double = 0
    var musicConfidence: Double = 0
    let signal: Signal
    var languageHint: String? = nil
    var spokenLanguage: SpokenLanguageAssessment? = nil
    var sampledSeconds: Double = 0
    var exceedsTranslationLimit = false
}
protocol ClipAudioInspecting: Sendable {
    func inspect(fileURL: URL) async -> ClipAudioAssessment
}
struct NoopClipAudioInspector: ClipAudioInspecting {
    func inspect(fileURL: URL) async -> ClipAudioAssessment { .init(signal: .unknown) }
}

nonisolated struct SpokenLanguageAssessment: Codable, Hashable, Sendable {
    var status: String
    var code: String?
    var confidence: Double?
    var reason: String?
    var method = "on_device_speech_text"
    var sampledSeconds: Double = 0
    static func unknown(_ reason: String) -> Self { .init(status: "unknown", reason: reason) }
    /// The language code when a clip already declares it (clips uploaded by older builds carry one), otherwise nil.
    var knownCode: String? { status == "likely" || status == "confirmed" ? code : nil }
}
