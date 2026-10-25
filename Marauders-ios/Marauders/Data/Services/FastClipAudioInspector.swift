import AVFoundation
import Foundation
import SoundAnalysis

/// A local signal/metadata hint, not speech recognition or a translation guarantee.
nonisolated struct FastClipAudioInspector: ClipAudioInspecting {
    @concurrent func inspect(fileURL: URL) async -> ClipAudioAssessment {
        guard fileURL.isFileURL else { return .init(signal: .unknown) }
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration).seconds
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let exceeds = size > 12 * 1024 * 1024
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return .init(signal: .noTrack, exceedsTranslationLimit: exceeds)
            }
            let extended = try? await track.load(.extendedLanguageTag)
            var language = Self.languageHint(extended)
            if language == nil { language = Self.languageHint(try? await track.load(.languageCode)) }
            guard duration.isFinite, duration > 0 else { return .init(signal: .unknown, languageHint: language, exceedsTranslationLimit: exceeds) }
            let window = min(1.0, duration)
            let last = max(0, duration - window)
            let starts = Array(Set([0, last / 2, last])).sorted()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            let scores = AudioClassificationScores()
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16000)
            request.overlapFactor = 0
            try analyzer.add(request, withObserver: scores)
            var position: AVAudioFramePosition = 0
            var sampledSeconds = 0.0
            var detected = false
            for start in starts {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { return .init(signal: detected ? .detected : .unknown, languageHint: language, sampledSeconds: sampledSeconds, exceedsTranslationLimit: exceeds) }
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16000), duration: CMTime(seconds: window, preferredTimescale: 16000))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? VideoExportError.exportFailed }
                defer { reader.cancelReading() }
                var power = 0.0, peak = 0.0
                var frames = 0
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { reader.cancelReading(); return .init(signal: detected ? .detected : .unknown, languageHint: language, sampledSeconds: sampledSeconds, exceedsTranslationLimit: exceeds) }
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    guard length > 0 else { continue }
                    var bytes = Data(count: length)
                    let status = bytes.withUnsafeMutableBytes { buffer in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count, destination: buffer.baseAddress!)
                    }
                    guard status == kCMBlockBufferNoErr else { throw VideoExportError.exportFailed }
                    let count = length / 4
                    if count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let destination = pcm.floatChannelData?[0] {
                        pcm.frameLength = AVAudioFrameCount(count)
                        bytes.withUnsafeBytes { raw in destination.update(from: raw.bindMemory(to: Float.self).baseAddress!, count: count) }
                        analyzer.analyze(pcm, atAudioFramePosition: position)
                        position += AVAudioFramePosition(count)
                    }
                    bytes.withUnsafeBytes { raw in
                        for offset in stride(from: 0, through: max(-1, raw.count - 4), by: 4) {
                            let value = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
                            if value.isFinite { power += value * value; peak = max(peak, abs(value)); frames += 1 }
                        }
                    }
                }
                guard reader.status == .completed else { throw reader.error ?? VideoExportError.exportFailed }
                sampledSeconds += Double(frames) / 16000
                if frames > 0, peak >= 0.005, sqrt(power / Double(frames)) >= 0.0005 { detected = true }
            }
            analyzer.completeAnalysis()
            let confidence = scores.snapshot()
            let content = Self.content(speech: confidence.0, music: confidence.1)
            return .init(content: detected ? content : .unknown, speechConfidence: confidence.0, musicConfidence: confidence.1, signal: detected ? .detected : .quietSamples, languageHint: language, sampledSeconds: sampledSeconds, exceedsTranslationLimit: exceeds)
        } catch { return .init(signal: .unknown) }
    }
    static func content(speech: Double, music: Double) -> ClipAudioAssessment.Content {
        if speech >= 0.5 { return music >= 0.5 ? .mixed : .speech }
        if music >= 0.7 && speech < 0.2 { return .music }
        return .unknown
    }
    static func languageHint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard tag != "und", tag != "zxx", tag.count <= 35,
              tag.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil else { return nil }
        return tag
    }
}

/// SoundAnalysis callbacks may arrive on its own queue.
nonisolated private final class AudioClassificationScores: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var speech = 0.0
    private var music = 0.0
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock()
        defer { lock.unlock() }
        speech = max(speech, result.classification(forIdentifier: "speech")?.confidence ?? 0)
        for label in ["music", "singing", "choir_singing", "rapping"] {
            music = max(music, result.classification(forIdentifier: label)?.confidence ?? 0)
        }
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}
    func snapshot() -> (Double, Double) {
        lock.lock()
        defer { lock.unlock() }
        return (speech, music)
    }
}
