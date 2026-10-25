import AVFoundation
import Foundation
import Testing
@testable import Marauders

@MainActor
struct ThaiDubbingTests {
    @Test func stereoAudioIsNormalizedAndSplitWithoutDroppingDuration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("stereo.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for frame in 0..<48000 {
            let value = Float(sin(Double(frame) * 440 * 2 * .pi / 48000) * 0.25)
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            for _ in 0..<141 { try file.write(from: buffer) }
        }
        let segments = try await SpeechAudioPreparation.chunks(from: source, directory: directory)
        #expect(segments.count == 8)
        var seconds = 0.0
        for segment in segments {
            let file = try AVAudioFile(forReading: segment)
            #expect(file.processingFormat.channelCount == 1)
            #expect(file.processingFormat.sampleRate == 16000)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            #expect(duration <= 20)
            seconds += duration
        }
        #expect(abs(seconds - 141) < 0.01)
    }

    @Test func originalSelectionClearsUnavailableState() {
        let model = ThaiDubbingViewModel()
        #expect(model.message == nil)
        #expect(!model.isProcessing)
        model.unavailableForTesting()
        #expect(model.message?.contains("บนอุปกรณ์") == true)
        model.useOriginal()
        #expect(model.message == nil)
        #expect(!model.isProcessing)
    }
    @Test func canceledSpeechWriterIgnoresLateBuffers() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                let writer = NarrationFileWriter(url: url, continuation: continuation)
                writer.cancel()
                writer.append(buffer)
                writer.cancel()
            }
            Issue.record("Canceled speech produced an audio URL")
        } catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func emptySpeechDoesNotProducePlayableFile() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        do {
            let _: URL = try await withCheckedThrowingContinuation { continuation in
                let writer = NarrationFileWriter(url: url, continuation: continuation)
                writer.append(empty)
                writer.append(empty)
            }
            Issue.record("Empty narration accepted")
        } catch { #expect(error is ThaiDubbingError) }
    }
    @Test func speechWriterClosesReadableAudioOnEndBuffer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        pcm.frameLength = 100
        for i in 0..<100 { pcm.floatChannelData![0][i] = 0 }
        let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        let output: URL = try await withCheckedThrowingContinuation { continuation in
            let writer = NarrationFileWriter(url: url, continuation: continuation)
            writer.append(pcm)
            writer.append(end)
            writer.append(end)
        }
        let file = try AVAudioFile(forReading: output)
        #expect(file.length == 100)
    }
}
