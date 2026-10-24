import AVFoundation
import Foundation

/// Decode compressed/video audio into bounded mono PCM WAV segments. Keeping
/// recognition requests short avoids depending on a single long-file final result.
nonisolated enum SpeechAudioPreparation {
    @concurrent static func chunks(from source: URL, directory: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ThaiDubbingError.speechUnclear }
        let reader = try AVAssetReader(asset: asset)
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
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard pcm.count + length <= 120 * 16000 * 2 + 65536 else {
                reader.cancelReading(); throw ThaiDubbingError.unsupported
            }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw ThaiDubbingError.failed }
            pcm.append(bytes)
        }
        guard reader.status == .completed else { throw reader.error ?? ThaiDubbingError.failed }
        guard !pcm.isEmpty else { throw ThaiDubbingError.speechUnclear }
        let segmentBytes = 20 * 16000 * 2
        var files: [URL] = []
        for start in stride(from: 0, to: pcm.count, by: segmentBytes) {
            try Task.checkCancellation()
            let payload = pcm.subdata(in: start..<min(start + segmentBytes, pcm.count))
            // AAC export can leave a silent tail. Digital silence has no words
            // to recognize, so omit it rather than waiting for a recognizer error.
            if payload.allSatisfy({ $0 == 0 }) { continue }
            let url = directory.appendingPathComponent("speech-\(files.count).wav")
            try wave(payload).write(to: url)
            files.append(url)
        }
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
