//
//  NarrationVoiceChoosing.swift
//  Marauders
//

import Foundation

/// Chooses the system speech voice that reads translated narration aloud.
protocol NarrationVoiceChoosing {
    /// The BCP-47 tag (such as "pt-BR") of the best voice installed for `language`, or nil when there is none. The
    /// caller asks the system for its own default voice in that language, so the viewer's voice settings apply.
    func voiceLanguageTag(for language: ListeningLanguage) -> String?
}
