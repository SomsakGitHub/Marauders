import AVFoundation
import Foundation

nonisolated enum DubbedAudioCacheEncoding {
    @concurrent static func encode(source: URL, destination: URL) async throws -> Data {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
            let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw DubbingError.failed }
        try await export.export(to: destination, as: .m4a)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4 * 1024 * 1024 else { throw DubbingError.failed }
        return try Data(contentsOf: destination)
    }
}
