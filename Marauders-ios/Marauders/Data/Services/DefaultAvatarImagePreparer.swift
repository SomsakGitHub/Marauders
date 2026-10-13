//
//  DefaultAvatarImagePreparer.swift
//  Marauders
//

import UIKit

struct DefaultAvatarImagePreparer: AvatarImagePreparing {
    func prepareJPEG(from data: Data, maxDimension: CGFloat = 512) -> Data? {
        guard let image = UIImage(data: data) else {
            return nil
        }
        return image.downscaled(maxDimension: maxDimension).jpegData(compressionQuality: 0.8)
    }
}

private extension UIImage {
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard maxDimension > 0, longestSide > maxDimension else {
            return self
        }
        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
