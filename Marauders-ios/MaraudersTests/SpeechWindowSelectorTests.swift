import Foundation
import Testing
@testable import Marauders

struct SpeechWindowSelectorTests {
    /// `speech` loud seconds then `quiet` seconds of near silence, repeated as given.
    private func clip(_ parts: [(loud: Bool, seconds: Int)]) -> [Double] {
        parts.flatMap { Array(repeating: $0.loud ? 0.1 : 0.0005, count: $0.seconds) }
    }

    @Test func aClipNoLongerThanOneWindowIsListenedToWhole() {
        #expect(SpeechWindowSelector.windows(loudness: clip([(true, 12)]), count: 2) == [0 ..< 12])
        #expect(SpeechWindowSelector.windows(loudness: clip([(false, 20)]), count: 1) == [0 ..< 20])
        #expect(SpeechWindowSelector.windows(loudness: [], count: 2).isEmpty)
        #expect(SpeechWindowSelector.windows(loudness: clip([(true, 30)]), count: 0).isEmpty)
    }

    @Test func aClipThatOpensWithSpeechKeepsItsOpening() {
        let loudness = clip([(true, 60)])
        #expect(SpeechWindowSelector.windows(loudness: loudness, count: 1) == [0 ..< 20])
        #expect(SpeechWindowSelector.windows(loudness: loudness, count: 2) == [0 ..< 20, 20 ..< 40])
    }

    @Test func aLongOpeningWithoutSpeechIsSkipped() {
        // 30 s of near silence, then 30 s of speech: the first window would say nothing about the language.
        let loudness = clip([(false, 30), (true, 30)])
        let windows = SpeechWindowSelector.windows(loudness: loudness, count: 1)
        #expect(windows == [30 ..< 50])
    }

    @Test func aSlightlyBetterLaterWindowDoesNotReplaceTheOpening() {
        // The opening has 18 speech seconds out of 20; a later window with all 20 is not worth moving for.
        let loudness = clip([(true, 18), (false, 2), (true, 40)])
        #expect(SpeechWindowSelector.windows(loudness: loudness, count: 1) == [0 ..< 20])
    }

    @Test func theBestWindowComesFirstAndTheSecondNeverOverlapsIt() {
        // The better stretch is the later one (20 loud seconds against 15), and it leads even though it comes second in the clip.
        let loudness = clip([(false, 5), (true, 15), (false, 10), (true, 20)])
        let windows = SpeechWindowSelector.windows(loudness: loudness, count: 2)
        #expect(windows.first == 30 ..< 50)
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.count == SpeechWindowSelector.windowSeconds || $0.count >= SpeechWindowSelector.shortestExtraSeconds })
        #expect(windows[1].upperBound <= windows[0].lowerBound || windows[1].lowerBound >= windows[0].upperBound)
    }

    @Test func aClipOnlyALittleLongerThanOneWindowStillGetsASecondWindowFromItsTail() {
        // 30 s of speech: the first 20 s, then the 10 s that remain, as before the selector existed.
        let loudness = clip([(true, 30)])
        #expect(SpeechWindowSelector.windows(loudness: loudness, count: 2) == [0 ..< 20, 20 ..< 30])
        // A tail under 5 s says too little to be asked about.
        #expect(SpeechWindowSelector.windows(loudness: clip([(true, 23)]), count: 2) == [0 ..< 20])
    }

    @Test func aSecondWindowWithoutSpeechIsLeftOut() {
        // 20 s of speech followed by silence: asking about the silence would only add doubt.
        let loudness = clip([(true, 20), (false, 40)])
        #expect(SpeechWindowSelector.windows(loudness: loudness, count: 2) == [0 ..< 20])
    }

    @Test func anOpeningOfPureSilenceYieldsToAnyLaterSpeech() {
        // 25 s of silence, then only 2 s of speech: still better than listening to nothing.
        let loudness = clip([(false, 25), (true, 2), (false, 10)])
        let windows = SpeechWindowSelector.windows(loudness: loudness, count: 1)
        #expect(windows.count == 1)
        #expect(windows[0].contains(25) && windows[0].contains(26))
    }

    @Test func quietTalkingUnderALoudBedStillCountsAsSound() {
        // 30 s of talking at 0.03, then 40 s of a bed at 0.2 (16 dB louder): the talking is not mistaken for silence.
        let loudness = Array(repeating: 0.03, count: 30) + Array(repeating: 0.2, count: 40)
        let speech = SpeechWindowSelector.speechSeconds(in: loudness)
        #expect(speech.prefix(30).allSatisfy { $0 == 1 })
        // The opening already has speech, and the bed is no better, so the opening is kept.
        #expect(SpeechWindowSelector.windows(loudness: loudness, count: 1) == [0 ..< 20])
    }

    @Test func aQuietClipIsJudgedByItsOwnLevel() {
        // Speech recorded far below full scale still counts, as long as it stands out from the hiss.
        let quiet = Array(repeating: 0.02, count: 30) + Array(repeating: 0.0008, count: 30)
        #expect(SpeechWindowSelector.speechSeconds(in: quiet).prefix(30).allSatisfy { $0 == 1 })
        #expect(SpeechWindowSelector.speechSeconds(in: quiet).suffix(30).allSatisfy { $0 == 0 })
        // Nothing but hiss never counts as speech, however the clip is scaled.
        #expect(SpeechWindowSelector.speechSeconds(in: Array(repeating: 0.001, count: 30)).allSatisfy { $0 == 0 })
    }

    @Test func loudnessIsTheRootMeanSquareOfEachSecond() {
        var pcm = Data()
        func append(_ value: Int16, seconds: Double) {
            for _ in 0 ..< Int(16000 * seconds) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
            }
        }
        append(0, seconds: 1)
        append(16384, seconds: 1)
        append(-16384, seconds: 0.5)
        let loudness = SpeechAudioPreparation.loudness(ofPCM: pcm)
        // The half second left over at the end is not measured.
        #expect(loudness.count == 2)
        #expect(loudness[0] == 0)
        #expect(abs(loudness[1] - 0.5) < 0.0001)
        #expect(SpeechAudioPreparation.loudness(ofPCM: Data()).isEmpty)
        // Audio shorter than a second still gets one value.
        var short = Data()
        for _ in 0 ..< 4000 { var little = Int16(8192).littleEndian; withUnsafeBytes(of: &little) { short.append(contentsOf: $0) } }
        #expect(SpeechAudioPreparation.loudness(ofPCM: short).count == 1)
    }

    /// The real path with a real audio file: 30 s of faint hiss, then 30 s of a loud tone standing in for speech.
    @Test func theWindowsWrittenForAClipThatOpensQuietlyComeFromTheLoudPart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var pcm = Data()
        func append(_ sample: Int16) {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        for index in 0 ..< 30 * 16000 { append(index % 2 == 0 ? 16 : -16) }
        for index in 0 ..< 30 * 16000 { append(Int16(10000 * sin(Double(index) * 2 * .pi * 440 / 16000))) }
        let source = folder.appendingPathComponent("source.wav")
        try SpeechAudioPreparation.wave(pcm).write(to: source)

        let output = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let files = try await SpeechAudioPreparation.detectionWindows(from: source, directory: output, count: 1)

        #expect(files.count == 1)
        let window = try #require(files.first)
        #expect(abs(SpeechAudioPreparation.seconds(ofWindow: window) - 20) < 0.1)
        let written = try Data(contentsOf: window).dropFirst(44)
        let level = SpeechAudioPreparation.loudness(ofPCM: Data(written))
        #expect(level.count == 20)
        #expect(level.allSatisfy { $0 > 0.1 })
    }
}
