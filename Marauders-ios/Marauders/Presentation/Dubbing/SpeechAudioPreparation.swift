import AVFoundation
import Foundation

/// Decode compressed/video audio into bounded mono PCM WAV segments. Keeping
/// recognition requests short avoids depending on a single long-file final result.
nonisolated enum SpeechAudioPreparation {
    /// `maximumSegments` stops reading once that many non-silent segments exist.
    @concurrent static func chunks(from source: URL, directory: URL, maximumSegments: Int? = nil) async throws -> [URL] {
        let (reader, output) = try await startReading(source)
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
        var reachedLimit = false
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw DubbingError.failed }
            pcm.append(bytes)
            while pcm.count >= segmentBytes {
                try store(pcm.prefix(segmentBytes))
                pcm.removeFirst(segmentBytes)
                if let maximumSegments, files.count >= maximumSegments { reachedLimit = true; break }
            }
            if reachedLimit { reader.cancelReading(); break }
        }
        if reachedLimit { return files }
        guard reader.status == .completed else { throw reader.error ?? DubbingError.failed }
        if !pcm.isEmpty { try store(pcm) }
        return files
    }

    /// Starts decoding the clip's first audio track to 16 kHz mono 16-bit PCM.
    private static func startReading(_ source: URL) async throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DubbingError.speechUnclear }
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
        guard reader.startReading() else { throw reader.error ?? DubbingError.failed }
        return (reader, output)
    }

    /// The stretches of a clip worth asking about its language: the most speech-like windows (see
    /// `SpeechWindowSelector`), written as WAV files in clip order. Only the first `maximumSeconds` of the
    /// clip are looked at, so a long clip costs no more than a short one.
    @concurrent static func detectionWindows(from source: URL, directory: URL, count: Int, maximumSeconds: Int = 300) async throws -> [URL] {
        let (reader, output) = try await startReading(source)
        let bytesPerSecond = 16000 * 2
        let limit = maximumSeconds * bytesPerSecond
        var pcm = Data()
        while pcm.count < limit, let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw DubbingError.failed }
            pcm.append(bytes)
        }
        if pcm.count >= limit {
            reader.cancelReading()
            pcm = pcm.prefix(limit)
        } else {
            guard reader.status == .completed else { throw reader.error ?? DubbingError.failed }
        }

        let loudness = Self.loudness(ofPCM: pcm)
        let windows = SpeechWindowSelector.windows(loudness: loudness, count: count)
        var files: [URL] = []
        try Task.checkCancellation()
        for range in windows {
            let start = range.lowerBound * bytesPerSecond
            // The last window reaches the end of the audio, including the part of a second left over.
            let end = range.upperBound == loudness.count ? pcm.count : range.upperBound * bytesPerSecond
            let payload = pcm[start ..< end]
            guard !payload.allSatisfy({ $0 == 0 }) else { continue }
            let url = directory.appendingPathComponent("speech-\(files.count).wav")
            try wave(Data(payload)).write(to: url)
            files.append(url)
        }
        return files
    }

    /// Root-mean-square level (0 to 1) of each whole second of 16 kHz mono 16-bit PCM. A part of a second left
    /// at the end is not measured, except when the audio is shorter than one second altogether.
    nonisolated static func loudness(ofPCM pcm: Data) -> [Double] {
        var result: [Double] = []
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let perSecond = 16000
            var index = 0
            while index < samples.count {
                let end = min(index + perSecond, samples.count)
                if end - index < perSecond, !result.isEmpty { break }
                var sum = 0.0
                for sample in samples[index ..< end] {
                    let value = Double(Int16(littleEndian: sample)) / 32768
                    sum += value * value
                }
                result.append((sum / Double(end - index)).squareRoot())
                index = end
            }
        }
        return result
    }

    /// How long a window made by `chunks` or `detectionWindows` is: 16 kHz mono 16-bit PCM behind a 44-byte header.
    nonisolated static func seconds(ofWindow url: URL) -> Double {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(max(size - 44, 0)) / 32_000
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
