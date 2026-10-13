//
//  MapClipSearch.swift
//  Marauders
//

import Foundation

/// Filters the clips already loaded onto the map. Matching is client-side and
/// covers the uploader handle, caption and country so the search
/// pill behaves like Instagram's place search without a network round-trip.
enum MapClipSearch {
    static func matches(_ clip: FeedVideo, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }

        return searchableFields(of: clip).contains { field in
            guard let field, !field.isEmpty else { return false }
            return field.lowercased().contains(needle)
        }
    }

    static func filter(_ clips: [FeedVideo], query: String) -> [FeedVideo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return clips }
        return clips.filter { matches($0, query: needle) }
    }

    private static func searchableFields(of clip: FeedVideo) -> [String?] {
        [
            clip.authorName,
            clip.caption,
            clip.country,
            clip.country.map { CountryCatalog.name(for: $0) },
        ]
    }
}
