//
//  TranscriptLanguageChecking.swift
//  Marauders
//

import Foundation

/// Judges whether what a speech model wrote down really is in the language it was told to write.
///
/// The Whisper model writes whatever it hears in the language it is told, so what came out has to read as that
/// language and have been heard with some confidence before it is translated, voiced and shared with every later
/// viewer of the clip.
protocol TranscriptLanguageChecking {
    /// Whether `text`, heard with `confidence` (0 to 1), is plausibly in `languageCode` (such as "nl"). A few words are
    /// judged on confidence alone, because a very short clip says too little to read a language from.
    func isPlausible(text: String, confidence: Double, languageCode: String) -> Bool
}
