import Foundation
import AVFoundation
import Speech

// No provider credentials or remote transcription/translation fallback.
enum DubbingError: LocalizedError {
    case unavailable, permission, unsupported, speechUnclear, failed
    /// No system speech voice is installed for the listening language (localized language name).
    case voiceUnavailable(language: String)
    /// Apple Translation has no route between the clip's language and the listening language.
    case pairUnsupported(source: String, target: String)
    /// The viewer's iPhone could not tell which language the clip speaks.
    case languageUndetected
    /// Same, on an iPhone without the language detection model, which only recognizes a few languages.
    case languageUndetectedWithoutModel
    /// The language detection model the viewer agreed to download could not be downloaded.
    case detectionModelDownloadFailed
    /// A speech model for dubbing could not be downloaded (localized language name).
    case speechModelDownloadFailed(language: String)
    /// The system lets an app keep only a few speech languages; the limit is reached.
    case speechModelLimit
    /// The viewer chose not to download the speech model that dubbing from this language needs.
    case speechModelDeclined(language: String)
    /// The download worked but the model would not load on this iPhone.
    case detectionModelUnusable
    /// There was not enough free storage for the language detection model.
    case detectionModelNoSpace
    /// The clip's language is known but this app cannot dub from it yet (localized language name).
    case sourceUnsupported(language: String)
    /// Not a failure: the clip already speaks the language the viewer asked for.
    case alreadyInListeningLanguage(language: String)

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This iPhone isn't ready to translate on-device. Install the languages in Settings › Language models, then try again.")
        case .permission: String(localized: "Allow speech recognition in Settings so the clip's speech can be transcribed.")
        case .unsupported: String(localized: "On-device translation supports clips up to 12 MB.")
        case .speechUnclear: String(localized: "Couldn't transcribe speech from this clip. Try a clip with clear speech, or listen to the original audio.")
        case .failed: String(localized: "Couldn't translate the audio on this iPhone. Listen to the original audio for now.")
        case .voiceUnavailable(let language): String(localized: "No \(language) voice is installed on this iPhone. Add one in Settings › Accessibility › Spoken Content › Voices.")
        case .pairUnsupported(let source, let target): String(localized: "Translating \(source) into \(target) isn't supported on this iPhone yet.")
        case .languageUndetected: String(localized: "Couldn't tell which language is spoken in this clip. Listen to the original audio.")
        case .languageUndetectedWithoutModel: String(localized: "Couldn't tell which language is spoken in this clip. Download the language detection model in Settings › Language models to recognize more languages. Listen to the original audio for now.")
        case .detectionModelDownloadFailed: String(localized: "Couldn't download the language detection model. Check your connection and try again. Listen to the original audio for now.")
        case .speechModelDownloadFailed(let language): String(localized: "Couldn't download the \(language) speech model. Check your connection and try again. Listen to the original audio for now.")
        case .speechModelLimit: String(localized: "This iPhone has reached its limit of downloaded speech languages. Remove one in Settings › Language models, then try again.")
        case .speechModelDeclined(let language): String(localized: "Dubbing from \(language) needs a one-time download of its speech model. Listen to the original audio for now.")
        case .detectionModelUnusable: String(localized: "Couldn't use the language detection model on this iPhone. Try downloading it again in Settings › Language models. Listen to the original audio for now.")
        case .detectionModelNoSpace: String(localized: "There isn't enough free storage for the language detection model. Free up some space and try again. Listen to the original audio for now.")
        case .sourceUnsupported(let language): String(localized: "AI dubbing from \(language) isn't supported yet.")
        case .alreadyInListeningLanguage(let language): String(localized: "This clip is already in \(language).")
        }
    }
}

/// AVSpeech's audio callback runs off the main actor. File writes and completion
/// are serialized here, with exactly one continuation completion, including cancel.
nonisolated final class NarrationFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<URL, Error>?
    private let url: URL
    init(url: URL, continuation: CheckedContinuation<URL, Error>) {
        self.url = url; self.continuation = continuation
    }
    func append(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { finishLocked(.failure(DubbingError.failed)); return }
        if pcm.frameLength == 0 {
            if file != nil { finishLocked(.success(url)) }
            else { finishLocked(.failure(DubbingError.failed)) }
            return
        }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
            try file?.write(from: pcm)
        } catch { finishLocked(.failure(error)) }
        _ = continuation
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        finishLocked(.failure(CancellationError()))
    }
    private func finishLocked(_ result: Result<URL, Error>) {
        file = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
