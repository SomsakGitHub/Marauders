import Foundation

struct ClipAudioAssessment: Sendable, Equatable, Codable, Hashable {
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

    var message: String {
        switch signal {
        case .detected: "พบเสียงในคลิป แต่ยังไม่ยืนยันว่าเป็นคำพูดหรือแปลได้"
        case .noTrack: "ไม่พบแทร็กเสียง คลิปยังอัปโหลดได้ แต่ไม่มีเสียงสำหรับแปลคำพูด"
        case .quietSamples: "ช่วงที่สุ่มตรวจมีเสียงเบาหรือเงียบ ยังไม่ยืนยันคำพูดในคลิปทั้งหมด"
        case .unknown: "ยังตรวจเสียงเบื้องต้นไม่ได้ ตรวจอีกครั้งได้ตอนเลือกแปลเสียง"
        }
    }
}
protocol ClipAudioInspecting: Sendable {
    func inspect(fileURL: URL) async -> ClipAudioAssessment
}
struct NoopClipAudioInspector: ClipAudioInspecting {
    func inspect(fileURL: URL) async -> ClipAudioAssessment { .init(signal: .unknown) }
}

struct SpokenLanguageAssessment: Codable, Hashable, Sendable {
    var status: String
    var code: String?
    var confidence: Double?
    var reason: String?
    var method = "on_device_speech_text"
    var sampledSeconds: Double = 0
    static func unknown(_ reason: String) -> Self { .init(status: "unknown", reason: reason) }
    /// A language the uploader picked; it replaces any on-device guess.
    static func chosen(_ code: String, sampledSeconds: Double = 0) -> Self {
        .init(status: "confirmed", code: code.lowercased(), method: "uploader", sampledSeconds: sampledSeconds)
    }
    /// The language code when it is known (detected with confidence, or chosen), otherwise nil.
    var knownCode: String? { status == "likely" || status == "confirmed" ? code : nil }
}
