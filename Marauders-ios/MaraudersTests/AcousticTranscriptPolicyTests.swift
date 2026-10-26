import Foundation
import Testing
@testable import Marauders

@MainActor
struct AcousticTranscriptPolicyTests {
    private func segment(_ text: String, logProbability: Double = -0.3, compression: Double = 1.2) -> AcousticSegment {
        AcousticSegment(text: text, averageLogProbability: logProbability, compressionRatio: compression)
    }

    @Test func theSegmentsOfAWindowAreJoinedInOrder() {
        let transcript = AcousticTranscriptPolicy.transcript(from: [
            segment("Goeiemorgen, kan ik u helpen?"),
            segment("Goeiemorgen, graag.")
        ])
        #expect(transcript.text == "Goeiemorgen, kan ik u helpen? Goeiemorgen, graag.")
    }

    @Test func confidenceIsTheLetterWeightedMeanProbability() {
        // 10 letters at -0.5 and 30 letters at -0.1: the mean log probability is -0.2.
        let transcript = AcousticTranscriptPolicy.transcript(from: [
            segment("abcdefghij", logProbability: -0.5),
            segment("abcdefghijklmnopqrstuvwxyzabcd", logProbability: -0.1)
        ])
        #expect(abs(transcript.confidence - exp(-0.2)) < 0.0001)
    }

    @Test func controlTokensAndStraySpacingAreRemoved() {
        let transcript = AcousticTranscriptPolicy.transcript(from: [
            segment("<|startoftranscript|><|nl|><|transcribe|><|0.00|>  Mooi,   dan wil ik graag<|2.48|> een kilo tomaten.\n")
        ])
        #expect(transcript.text == "Mooi, dan wil ik graag een kilo tomaten.")
    }

    @Test func theDashThatMarksANewSpeakersTurnIsRemoved() {
        #expect(AcousticTranscriptPolicy.transcript(from: [segment("Kan ik met mijn pinpas betalen? -Ja, natuurlijk.")]).text
                == "Kan ik met mijn pinpas betalen? Ja, natuurlijk.")
        #expect(AcousticTranscriptPolicy.transcript(from: [segment("— Dank u wel. –Graag gedaan.")]).text == "— Dank u wel. Graag gedaan.")
        // A dash inside a word, or one that stands alone, is left as it is.
        #expect(AcousticTranscriptPolicy.transcript(from: [segment("Het is een e-mail van tien - twaalf uur.")]).text == "Het is een e-mail van tien - twaalf uur.")
    }

    @Test func musicSymbolsAndStraySoundsAreNotWords() {
        // The base model wrote a note symbol for the music at the end of the test clip.
        #expect(AcousticTranscriptPolicy.transcript(from: [segment("♫", logProbability: -0.16)]) == AcousticTranscript(text: "", confidence: 0))
        #expect(AcousticTranscriptPolicy.transcript(from: [segment(" . ")]).text.isEmpty)
        #expect(AcousticTranscriptPolicy.transcript(from: [segment("Ja, natuurlijk.")]).text == "Ja, natuurlijk.")
    }

    @Test func aSubtitleCreditWrittenForSilenceIsDropped() {
        // Whisper small ended the test clip with this, with high confidence.
        let credit = AcousticTranscriptPolicy.transcript(from: [
            segment("Dank u wel."),
            segment("(C) TV GELDERLAND 2020", logProbability: -0.12)
        ])
        #expect(credit.text == "Dank u wel.")
        for text in ["Ondertitels ingediend door de Amara.org gemeenschap", "Untertitel der Amara.org-Community", "© NPO 2021", "kijk op www.example.nl"] {
            #expect(AcousticTranscriptPolicy.transcript(from: [segment(text)]).text.isEmpty, "\(text)")
        }
    }

    @Test func aModelStuckInALoopIsDropped() {
        let transcript = AcousticTranscriptPolicy.transcript(from: [
            segment("Ja, natuurlijk."),
            segment("Dank u. Dank u. Dank u. Dank u. Dank u. Dank u. Dank u.", compression: 3.1)
        ])
        #expect(transcript.text == "Ja, natuurlijk.")
    }

    /// WhisperKit 1.1.1 reports no no-speech probability, so a stock phrase it writes for silence is not recognised
    /// as such; this documents that gap instead of pretending the policy covers it.
    @Test func aStockPhraseWrittenForSilenceIsNotCaughtButIsLowConfidenceTextAtMost() {
        let transcript = AcousticTranscriptPolicy.transcript(from: [segment("Bedankt voor het kijken!", logProbability: -0.8)])
        #expect(transcript.text == "Bedankt voor het kijken!")
        #expect(transcript.confidence < 0.5)
    }

    @Test func nothingHeardGivesAnEmptyTranscriptWithNoConfidence() {
        #expect(AcousticTranscriptPolicy.transcript(from: []) == AcousticTranscript(text: "", confidence: 0))
    }

    @Test func aGoodDutchTranscriptIsPlausibleAndAnotherLanguageIsNot() {
        let dutch = AcousticTranscriptPolicy.transcript(from: [
            segment("Mooi, dan wil ik graag een kilo tomaten."),
            segment("Natuurlijk, nog iets anders?")
        ])
        #expect(LanguageEvidence.transcriptIsPlausible(text: dutch.text, confidence: dutch.confidence, languageCode: "nl"))
        // The model writes whatever it hears in the language it is told; text that reads as English is not Dutch.
        let english = "Good morning, can I help you? I would like a kilo of tomatoes and two cucumbers please."
        #expect(!LanguageEvidence.transcriptIsPlausible(text: english, confidence: 0.8, languageCode: "nl"))
    }
}
