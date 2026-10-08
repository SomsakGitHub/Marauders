//
//  VideoPlaybackConfigurator.swift
//  Marauders
//

import AVFoundation

enum VideoPlaybackConfigurator {
    static func activateAudioSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            AppLog.error("player", "audio session failed: \(error.localizedDescription)")
        }
    }
}
