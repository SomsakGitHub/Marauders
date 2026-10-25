//
//  FeedVideo.swift
//  Marauders
//

import Foundation

struct FeedVideo: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let streamURL: URL
    let latitude: Double?
    let longitude: Double?
    /// ISO 3166-1 alpha-2 country of the uploader, when known.
    let country: String?
    /// Display handle of the uploader, when known.
    let authorName: String?
    /// Avatar image URL of the uploader, when known.
    let authorAvatarURL: URL?
    /// Caption text shown with the clip, when known.
    let audioAssessment: ClipAudioAssessment?
    let caption: String?

    /// Music-only advisories keep original playback without an AI generation entry point.
    var allowsThaiAudio: Bool { audioAssessment?.content != .music }

    /// Language the Thai narration is translated from.
    var dubbingSourceLanguage: DubbingSourceLanguage {
        DubbingSourceLanguage(spokenLanguage: audioAssessment?.spokenLanguage)
    }

    init(
        id: UUID = UUID(),
        streamURL: URL,
        latitude: Double? = nil,
        longitude: Double? = nil,
        country: String? = nil,
        authorName: String? = nil,
        authorAvatarURL: URL? = nil,
        caption: String? = nil,
        audioAssessment: ClipAudioAssessment? = nil
    ) {
        self.id = id
        self.streamURL = streamURL
        self.latitude = latitude
        self.longitude = longitude
        self.country = country
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.caption = caption
        self.audioAssessment = audioAssessment
    }
}
