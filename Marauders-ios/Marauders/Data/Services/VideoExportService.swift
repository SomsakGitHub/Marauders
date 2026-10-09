//
//  VideoExportService.swift
//  Marauders
//

import AVFoundation

enum VideoExportError: LocalizedError {
    case notExportable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .notExportable:
            return "Couldn’t convert video to MP4"
        case .exportFailed:
            return "Video conversion failed"
        }
    }
}

enum VideoExportService {
    /// Re-encode to MP4 (H.264) for reliable streaming and upload.
    static func mp4URLForUpload(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw VideoExportError.notExportable }

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1280x720
        ) else {
            throw VideoExportError.notExportable
        }

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
            .appendingPathExtension("mp4")

        exportSession.outputURL = destination
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: VideoExportError.exportFailed)
                default:
                    continuation.resume(throwing: VideoExportError.exportFailed)
                }
            }
        }

        AppLog.info("upload", "exported mp4 bytes=\(fileSize(at: destination))")
        return destination
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }
}
