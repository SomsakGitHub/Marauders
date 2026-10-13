//
//  AvatarImagePreparing.swift
//  Marauders
//

import Foundation

/// Prepares a picked image for avatar upload (downscale + re-encode).
protocol AvatarImagePreparing: Sendable {
    /// Downscales and re-encodes raw image data (any supported format) to a compact JPEG.
    /// Returns `nil` when the data is not a decodable image.
    func prepareJPEG(from data: Data, maxDimension: CGFloat) -> Data?
}
