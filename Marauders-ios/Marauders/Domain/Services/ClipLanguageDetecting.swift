//
//  ClipLanguageDetecting.swift
//  Marauders
//

import Foundation

/// Works out which language a clip's speech is in, on the viewer's iPhone.
protocol ClipLanguageDetecting {
    /// The best guess among `candidates`, or nil when the sample is unclear or ambiguous.
    func detect(sample: URL, among candidates: [SpeechLanguageCandidate]) async -> SpeechLanguageDetection?
}

/// Brings a clip to a local file the audio can be read from.
protocol ClipFileLoading {
    /// The clip itself when it is already a file, otherwise a size-bounded download into `folder`.
    /// `check` throws to stop early, for example when the viewer chose the original audio.
    func load(_ url: URL, into folder: URL, check: () throws -> Void) async throws -> URL
}
