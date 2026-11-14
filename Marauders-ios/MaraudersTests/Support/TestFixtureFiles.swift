//
//  TestFixtureFiles.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

enum TestFixtureFiles {
    static func temporaryVideoFile(byteCount: Int, extension ext: String = "mp4") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
            .appendingPathExtension(ext)
        let data = Data(repeating: 0xAB, count: max(byteCount, 0))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A mono 16 kHz WAV file holding a 440 Hz tone, which the real clip audio inspector reports as `.detected`.
    static func temporaryToneFile(seconds: Double = 2) throws -> URL {
        let frames = Int(seconds * 16000)
        var pcm = Data(count: frames * 2)
        pcm.withUnsafeMutableBytes { bytes in
            for frame in 0..<frames {
                let value = Int16(sin(Double(frame) * 440 * 2 * .pi / 16000) * 8000).littleEndian
                bytes.storeBytes(of: value, toByteOffset: frame * 2, as: Int16.self)
            }
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
            .appendingPathExtension("wav")
        try SpeechAudioPreparation.wave(pcm).write(to: url, options: .atomic)
        return url
    }
}
