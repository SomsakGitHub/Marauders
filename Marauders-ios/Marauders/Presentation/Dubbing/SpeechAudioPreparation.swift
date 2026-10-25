import AVFoundation
import Foundation

/// Decode compressed/video audio into bounded mono PCM WAV segments. Keeping
/// recognition requests short avoids depending on a single long-file final result.
nonisolated enum SpeechAudioPreparation {
    @concurrent static func chunks(from source: URL, directory: URL, maximumSampleSeconds: Double? = nil) async throws -> [URL] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ThaiDubbingError.speechUnclear }
        let reader = try AVAssetReader(asset: asset)
        if let limit = maximumSampleSeconds {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: min(8, max(0.5, limit)), preferredTimescale: 16000))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ThaiDubbingError.failed }
        var pcm = Data()
        let segmentBytes = 20 * 16000 * 2
        var files: [URL] = []
        func store(_ payload: Data) throws {
            // Keep silent-tail handling without retaining the whole decoded clip.
            guard !payload.allSatisfy({ $0 == 0 }) else { return }
            let url = directory.appendingPathComponent("speech-\(files.count).wav")
            try wave(payload).write(to: url)
            files.append(url)
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw ThaiDubbingError.failed }
            pcm.append(bytes)
            while pcm.count >= segmentBytes {
                try store(pcm.prefix(segmentBytes))
                pcm.removeFirst(segmentBytes)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? ThaiDubbingError.failed }
        if !pcm.isEmpty { try store(pcm) }
        return files
    }

    static func wave(_ pcm: Data) -> Data {
        var result = Data()
        func ascii(_ string: String) { result.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcm.count) + 36); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
