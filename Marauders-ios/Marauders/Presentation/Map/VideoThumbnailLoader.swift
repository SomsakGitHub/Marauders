//
//  VideoThumbnailLoader.swift
//  Marauders
//

import AVFoundation
import UIKit

/// Generates and caches small video frame thumbnails for map pins (HTTPS streams only).
actor VideoThumbnailLoader {
    static let shared = VideoThumbnailLoader()

    private var cache: [URL: UIImage] = [:]
    private let maxCacheCount = 40

    func thumbnail(for url: URL, maxPixelSize: CGFloat = 128) async -> UIImage? {
        if let cached = cache[url] { return cached }
        guard url.scheme?.lowercased() == "https" else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        do {
            let cgImage = try await generator.image(at: time).image
            let image = UIImage(cgImage: cgImage)
            store(image, for: url)
            return image
        } catch {
            return nil
        }
    }

    private func store(_ image: UIImage, for url: URL) {
        if cache.count >= maxCacheCount, let key = cache.keys.first {
            cache.removeValue(forKey: key)
        }
        cache[url] = image
    }
}
