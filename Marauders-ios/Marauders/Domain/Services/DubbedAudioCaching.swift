import CryptoKit
import Foundation

/// How a clip's source URL is fingerprinted, so saved AI audio is only reused for the exact same source file.
nonisolated enum DubbedAudioSourceHash {
    static func of(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum DubbedAudioCacheError: Error {
    case http(Int)
    /// The cache behind this protocol cannot take reports.
    case reportUnsupported
}

/// What the Worker did with a report about a saved AI audio file.
enum DubbedAudioReportOutcome: Equatable, Sendable {
    /// The report was recorded; the audio stays until enough other viewers report it too.
    case reported
    /// The audio was deleted, so the next viewer can save a replacement.
    case removed
    /// Nothing is saved for that clip and language, so there is nothing to report.
    case missing
}

protocol DubbedAudioCaching: Sendable {
    func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL?
    func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws
    /// The words the saved AI audio reads, for subtitles; nil when none were saved.
    func lookupText(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async -> String?
    func storeText(videoID: UUID, sourceURL: URL, language: ListeningLanguage, text: String) async throws
    /// Tells the Worker this saved AI audio is bad. Signed-in viewers only.
    func report(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> DubbedAudioReportOutcome
    /// Who is signed in, or nil for a guest. Guests cannot report, so they are not offered the button.
    var reporterID: String? { get }
}

extension DubbedAudioCaching {
    func lookupText(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async -> String? { nil }
    func storeText(videoID: UUID, sourceURL: URL, language: ListeningLanguage, text: String) async throws {}
    func report(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> DubbedAudioReportOutcome {
        throw DubbedAudioCacheError.reportUnsupported
    }
    var reporterID: String? { nil }
}

/// A cache with nothing in it that keeps nothing it is given.
struct NoDubbedAudioCache: DubbedAudioCaching {
    func lookup(videoID: UUID, sourceURL: URL, language: ListeningLanguage) async throws -> URL? { nil }
    func store(videoID: UUID, sourceURL: URL, language: ListeningLanguage, audio: Data) async throws {}
}
