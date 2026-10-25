import Foundation
import Speech

enum SpeechPermission {
    /// Asks for speech recognition once; true when the viewer has allowed it.
    static func request() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
            }
        default: return false
        }
    }
}
