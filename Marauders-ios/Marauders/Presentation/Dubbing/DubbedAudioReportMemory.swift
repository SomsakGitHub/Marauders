import Foundation

/// Remembers, on this iPhone only, which saved AI audio files the viewer already reported, so the
/// Report button is not offered twice for the same audio. Keyed by signed-in user, clip, language and clip revision;
/// the oldest entries are dropped past `limit`.
@MainActor
final class DubbedAudioReportMemory {
    static let shared: DubbedAudioReportMemory = {
        if AppRuntimeConfiguration.isUITesting {
            let suite = "marauders.uitest.reported"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return DubbedAudioReportMemory(defaults: defaults)
        }
        return DubbedAudioReportMemory()
    }()

    private static let storageKey = "reportedDubbedAudio.v1"
    private let defaults: UserDefaults
    private let limit: Int
    private var keys: [String]

    init(defaults: UserDefaults = .standard, limit: Int = 300) {
        self.defaults = defaults
        self.limit = limit
        keys = defaults.stringArray(forKey: Self.storageKey) ?? []
    }

    nonisolated static func key(user: String, videoID: UUID, language: ListeningLanguage, sourceURL: URL) -> String {
        "\(user.lowercased())|\(videoID.uuidString.lowercased())|\(language.code)|\(DubbedAudioCacheClient.sourceHash(sourceURL))"
    }

    func hasReported(user: String, videoID: UUID, language: ListeningLanguage, sourceURL: URL) -> Bool {
        keys.contains(Self.key(user: user, videoID: videoID, language: language, sourceURL: sourceURL))
    }

    func remember(user: String, videoID: UUID, language: ListeningLanguage, sourceURL: URL) {
        let key = Self.key(user: user, videoID: videoID, language: language, sourceURL: sourceURL)
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > limit { keys.removeFirst(keys.count - limit) }
        defaults.set(keys, forKey: Self.storageKey)
    }
}
