import AVFoundation
import Foundation
import Testing
@testable import Marauders

@MainActor
struct FastClipAudioInspectorTests {
    @Test func conservativeSpeechMusicPolicy() {
        #expect(FastClipAudioInspector.content(speech: 0.8, music: 0.1) == .speech)
        #expect(FastClipAudioInspector.content(speech: 0.8, music: 0.8) == .mixed)
        #expect(FastClipAudioInspector.content(speech: 0.1, music: 0.9) == .music)
        #expect(FastClipAudioInspector.content(speech: 0.3, music: 0.9) == .unknown)
        #expect(FastClipAudioInspector.content(speech: 0, music: 0) == .unknown)
    }
    @Test func musicHidesAIAudioEntryWhileUnknownAndSpeechRemainAvailable() {
        let url = URL(string: "https://example.com/video.mp4")!
        for content in [ClipAudioAssessment.Content.speech, .mixed, .unknown, .music] {
            let clip = FeedVideo(streamURL: url, audioAssessment: .init(content: content, signal: .detected))
            #expect(clip.allowsAIAudio == (content != .music))
        }
        #expect(FeedVideo(streamURL: url).allowsAIAudio)
    }
    private func wave(duration: Double = 2, toneAfter: Double? = nil) throws -> URL {
        let frames = Int(duration * 16000)
        var pcm = Data(repeating: 0, count: frames * 2)
        if let toneAfter {
            pcm.withUnsafeMutableBytes { bytes in
                for frame in 0..<frames where Double(frame) / 16000 >= toneAfter {
                    let value = Int16(sin(Double(frame) * 440 * 2 * .pi / 16000) * 8000).littleEndian
                    bytes.storeBytes(of: value, toByteOffset: frame * 2, as: Int16.self)
                }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try SpeechAudioPreparation.wave(pcm).write(to: url)
        return url
    }
    @Test func detectsSignalWithoutClaimingSpeechOrLanguage() async throws {
        let file = try wave(toneAfter: 0)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await FastClipAudioInspector().inspect(fileURL: file)
        #expect(result.signal == .detected)
        #expect(result.languageHint == nil)
        #expect(result.message.contains("ยังไม่ยืนยัน"))
        #expect(result.sampledSeconds > 0 && result.sampledSeconds <= 3.1)
    }
    @Test func samplingLaterInClipFindsAudioAfterSilentIntro() async throws {
        let file = try wave(toneAfter: 1.3)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await FastClipAudioInspector().inspect(fileURL: file)
        #expect(result.signal == .detected)
    }
    @Test func quietSamplesAreAdvisoryAndNotSpeechProof() async throws {
        let file = try wave()
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await FastClipAudioInspector().inspect(fileURL: file)
        #expect(result.signal == .quietSamples)
        #expect(result.message.contains("ช่วงที่สุ่มตรวจ"))
    }
    @Test func longClipDoesNotExceedTranslationLimitByDuration() async throws {
        let file = try wave(duration: 121)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await FastClipAudioInspector().inspect(fileURL: file)
        #expect(!result.exceedsTranslationLimit)
        #expect(result.sampledSeconds <= 3.1)
    }
    @Test func unreadableOrRemoteFilesStayUnknown() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data([1,2,3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await FastClipAudioInspector().inspect(fileURL: file).signal == .unknown)
        #expect(await FastClipAudioInspector().inspect(fileURL: URL(string: "https://example.invalid/video.mp4")!).signal == .unknown)
    }
    @Test func languageHintsRejectUnknownAndMalformedMetadata() {
        #expect(FastClipAudioInspector.languageHint("en-US") == "en-us")
        #expect(FastClipAudioInspector.languageHint("eng") == "eng")
        for raw in ["und", "zxx", "", "not a language", "<script>"] {
            #expect(FastClipAudioInspector.languageHint(raw) == nil)
        }
    }
    @Test func videoWithoutAudioHasNoTrack() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * 32)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        #expect(adapter.append(buffer, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        #expect(await FastClipAudioInspector().inspect(fileURL: file).signal == .noTrack)
    }
}
