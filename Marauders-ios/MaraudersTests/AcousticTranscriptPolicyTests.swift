import Foundation
import Testing
@testable import Marauders

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

    @MainActor @Test func aGoodDutchTranscriptIsPlausibleAndAnotherLanguageIsNot() {
        let dutch = AcousticTranscriptPolicy.transcript(from: [
            segment("Mooi, dan wil ik graag een kilo tomaten."),
            segment("Natuurlijk, nog iets anders?")
        ])
        #expect(LanguageEvidence.transcriptIsPlausible(text: dutch.text, confidence: dutch.confidence, languageCode: "nl"))
        // The model writes whatever it hears in the language it is told; text that reads as English is not Dutch.
        let english = "Good morning, can I help you? I would like a kilo of tomatoes and two cucumbers please."
        #expect(!LanguageEvidence.transcriptIsPlausible(text: english, confidence: 0.8, languageCode: "nl"))
    }

    // MARK: Labels, music and credits

    private func text(_ written: String) -> String {
        AcousticTranscriptPolicy.transcript(from: [segment(written)]).text
    }

    /// Every one of these was written by Whisper base for noise, music or near silence in the language sweep.
    @Test(arguments: [
        "[BLANK_AUDIO]", "* Musik *", "[Música de cierre]", "[MÚSICA DE FUNDO]", "[SOM DE FUNDO]", "[Loud mumbling]", "[Música]",
        "(water flowing)", "(soft music)", "*Musique*", "*musique de la salle de la pêche*", "[...müzik çalıyor...]", "[เสียงดนตรี]", "(音楽)", "[музыка]"
    ])
    func aLabelWrittenForNoiseIsNotSpeech(_ label: String) {
        #expect(text(label).isEmpty, "\(label)")
    }

    @Test(arguments: ["(Applaus)", "（音楽）", "【音楽】", "*Musik*", "**Musik**", "** Musik **", "[ Silence ]", "[Muziek] [Applaus]", "- [BLANK_AUDIO]", "[[BLANK_AUDIO]]", "((Applaus))", "[Music [loud]]"])
    func eachKindOfLabelOnItsOwnIsNotSpeech(_ label: String) {
        #expect(text(label).isEmpty, "\(label)")
    }

    @Test func aLabelNextToSpeechGoesAndTheSpeechStays() {
        #expect(text("Thank you very much, have a nice day. [BLANK_AUDIO]") == "Thank you very much, have a nice day.")
        #expect(text("[Música] Muchas gracias, que tenga un buen día.") == "Muchas gracias, que tenga un buen día.")
        #expect(text("Ja (Applaus) dank u wel.") == "Ja dank u wel.")
        #expect(text("Danke * Musik * schön") == "Danke schön")
        #expect(text("Ja[Applaus]dank u wel.") == "Ja dank u wel.")
        #expect(text("ありがとうございます（音楽）よい一日を") == "ありがとうございます よい一日を")
        #expect(text("ありがとう【音楽】") == "ありがとう")
        #expect(text("[Music [loud]] Dank u wel.") == "Dank u wel.")
        #expect(text("-[Muziek] Dank u wel.") == "Dank u wel.")
    }

    /// The price of stripping parentheses: a remark in brackets is lost, because the model writes sounds that way far more often.
    @Test func aParentheticalRemarkIsLostButTheSentenceStays() {
        #expect(text("Het kost € 12,40 (inclusief btw) en het is van de EU.") == "Het kost € 12,40 en het is van de EU.")
    }

    @Test func aStrayMarkOrArithmeticIsNotALabel() {
        #expect(text("Het kost 5 * 3 euro") == "Het kost 5 * 3 euro")
        #expect(text("Het kost 5 * 3 * 4 euro") == "Het kost 5 * 3 * 4 euro")
        #expect(text("Dan zei hij [ en toen niets meer") == "Dan zei hij [ en toen niets meer")
        #expect(text("Dan zei hij ] en ( toen ) niets") == "Dan zei hij ] en niets")
    }

    @Test func aLongStretchInBracketsIsSpeechNotALabel() {
        let aside = "(dat zei hij gisteren tegen mij toen wij samen naar de markt liepen om fruit te kopen)"
        #expect(aside.count > AcousticTranscriptPolicy.longestLabel)
        #expect(text("Hij zei het. \(aside)") == "Hij zei het. \(aside)")
    }

    @Test(arguments: ["♪ la la la la ♪", "Dank u wel ♪", "🎶 Hallo allemaal", "♫", "♬ muziek", "🎵", "♩ Hallo", "🎼 Dank u wel", "Hij zei “♪” en lachte"])
    func aSegmentWithMusicNotesIsMusicNotSpeech(_ written: String) {
        #expect(text(written).isEmpty, "\(written)")
    }

    // One realistic credit per marker, holding exactly that marker, so a marker that is removed or mistyped fails here.
    private static let creditFixtures: [String: String] = [
        "amara.org": "Amara.org", "©": "© NPO", "www.": "www.voorbeeld.nl", "http": "http voorbeeld", "otter.ai": "Otter.ai",
        "subtitles by": "Subtitles by Jan", "subtitled by": "Subtitled by Jan", "captions by": "Captions by Jan", "captioned by": "Captioned by Jan",
        "ondertitel": "Ondertitels ingediend door de gemeenschap", "tv gelderland": "TV Gelderland", "tt888": "TT888 Jan",
        "untertitel": "Untertitel der Gemeinschaft", "stephanie geiges": "Stephanie Geiges",
        "sous-titr": "Sous-titrage Jan", "sous titr": "Sous titrage Jan", "soustitreur": "SousTitreur.com",
        "subtítulos": "Subtítulos por Jan", "subtitulos": "Subtitulos por Jan", "subtitulado por": "Subtitulado por Jan",
        "legendas pela": "Legendas pela comunidade", "legendado por": "Legendado por Jan",
        "sottotitoli": "Sottotitoli di Jan", "qtss": "QTSS",
        "субтитр": "Субтитры от Яна", "корректор а.": "Корректор А.Егорова", "dimatorzok": "DimaTorzok",
        "napisy stworzone": "Napisy stworzone przez Jana", "napisy wykonał": "Napisy wykonał Jan", "tłumaczenie i napisy": "Tłumaczenie i napisy Jan",
        "altyazı": "Altyazı M.K.", "altyazi": "Altyazi M.K.",
        "undertexter": "Undertexter av Jan", "undertekster": "Undertekster af Jan", "teksting av": "Teksting av Jan", "nicolai winther": "Nicolai Winther",
        "نانسي قنقر": "نانسي قنقر", "ترجمة نانسي": "ترجمة نانسي",
        "字幕由": "字幕由小明提供", "字幕志愿者": "字幕志愿者小明", "字幕志願者": "字幕志願者小明", "中文字幕": "中文字幕小明",
        "优优独播剧场": "优优独播剧场", "優優獨播劇場": "優優獨播劇場", "明镜与点点栏目": "明镜与点点栏目", "明鏡與點點": "明鏡與點點",
        "字幕制作": "字幕制作小明", "字幕提供": "字幕提供小明", "자막 제공": "자막 제공 김", "한글자막": "한글자막 김",
        "phụ đề": "Phụ đề bởi Nam", "ghiền mì gõ": "Ghiền Mì Gõ", "bỏ lỡ những video": "Để không bỏ lỡ những video",
        "subtitle oleh": "Subtitle oleh Budi"
    ]

    @Test func everyCreditMarkerHasARealisticExampleThatMatchesOnlyIt() {
        for marker in AcousticTranscriptPolicy.creditMarkers {
            guard let example = Self.creditFixtures[marker] else {
                Issue.record("no example for the marker \"\(marker)\""); continue
            }
            #expect(AcousticTranscriptPolicy.creditMarkers.filter { example.lowercased().contains($0) } == [marker], "\(marker)")
            #expect(text(example).isEmpty, "\(marker)")
        }
        #expect(Set(Self.creditFixtures.keys) == Set(AcousticTranscriptPolicy.creditMarkers))
    }

    /// Credits and sign-offs written by the models in the sweep, word for word.
    @Test(arguments: [
        "TV GELDERLAND 2021.", "(C) TV GELDERLAND 2020", "TV GELDERLAND 2020.", "Редактор субтитров А.Синецкая Корректор А.Егорова",
        "Để không bỏ lỡ những video hấp dẫn", "Ondertitels ingediend door de Amara.org gemeenschap", "請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目",
        "(C) NPO", " (c) Jan", "BBC NEWS 2019", "NPO 2021", "ZDF 2020."
    ])
    func aCreditWrittenForSilenceIsDropped(_ credit: String) {
        #expect(text(credit).isEmpty, "\(credit)")
    }

    @Test func aCreditStuckToSpeechTakesOnlyItsOwnSentence() {
        #expect(text("Dank u wel. TV GELDERLAND 2021.") == "Dank u wel.")
        #expect(text("Dank u wel. NPO 2021") == "Dank u wel.")
        #expect(text("Dank u wel, fijne dag. Ondertitels ingediend door de Amara.org gemeenschap") == "Dank u wel, fijne dag.")
        #expect(text("Ja, dank u wel [Ondertiteld door NPO]") == "Ja, dank u wel")
        #expect(text("Спасибо. Редактор субтитров А.Синецкая Корректор А.Егорова") == "Спасибо.")
        #expect(text("ありがとうございます。字幕制作:山田") == "ありがとうございます。")
    }

    @Test func aCopyrightLineIsCaughtBeforeAndAfterTheLabelsAreStripped() {
        #expect(text("(C) NPO").isEmpty)                    // the sign is inside brackets that would be stripped
        #expect(text("[Muziek] NPO 2021.").isEmpty)         // the credit is only capitals once the label is gone
        #expect(text("[Muziek] Dank u wel.") == "Dank u wel.")
    }

    @Test func aYearInSpeechIsNotACredit() {
        #expect(text("In 2021 we went to Berlin.") == "In 2021 we went to Berlin.")
        #expect(text("Ik ben geboren in 1999.") == "Ik ben geboren in 1999.")
        #expect(text("2021年に東京へ行きました。") == "2021年に東京へ行きました。")
        #expect(text("В 2020 году мы переехали.") == "В 2020 году мы переехали.")
        #expect(text("Ik bel NPO in 2021") == "Ik bel NPO in 2021")
    }

    /// An acronym and a year in a language without capital letters: every letter has no case, so nothing is shouted.
    @Test(arguments: ["我们在2021年加入了WTO。", "ZDFは2021年に始まりました", "삼성은 2020년에 LG와 합병했다", "2021年にNHKで放送されました。", "ในปี 2020 BMW เปิดตัวรุ่นใหม่", "في عام 2020 أعلنت IBM عن ذلك"])
    func anAcronymAndAYearInALanguageWithoutCapitalsIsNotACredit(_ line: String) {
        #expect(text(line) == line, "\(line)")
    }

    @Test func aNumberThatIsNotAYearIsNotOne() {
        #expect(text("NASA 12000").contains("NASA"))
        #expect(text("TEL 0612192033").contains("TEL"))
        #expect(text("ROOM 12019").contains("ROOM"))
    }

    @Test(arguments: [
        "Goeiemorgen, kan ik u helpen?", "Guten Morgen, kann ich Ihnen helfen?", "Bonjour, je peux vous aider ?",
        "Buenos días, ¿puedo ayudarle?", "Bom dia, posso ajudar?", "Buongiorno, posso aiutarla?", "Dzień dobry, w czym mogę pomóc?",
        "Доброе утро, чем могу помочь?", "Доброго ранку, чим можу допомогти?", "Günaydın, size nasıl yardımcı olabilirim?",
        "God morgon, kan jag hjälpa dig?", "Godmorgen, kan jeg hjælpe dig?", "God morgen, kan jeg hjelpe deg?",
        "صباح الخير، هل أستطيع مساعدتك؟", "早上好，需要帮忙吗？", "おはようございます、何かお探しですか？", "안녕하세요, 도와드릴까요?",
        "สวัสดีตอนเช้า มีอะไรให้ช่วยไหมคะ", "Chào buổi sáng, tôi có thể giúp gì cho bạn?", "Selamat pagi, ada yang bisa saya bantu?",
        "Thank you very much, have a nice day.", "Dat is dan 4 euro 50, alstublieft.", "Ik sta hier sinds 8 uur, het is NU 12 uur.",
        "Mijn nummer is 06 12 34 56 78 en ik woon in de A12.", "Het kost € 12,40 en het is van de EU.", "Hij schreef a) en b) maar niet c.",
        "We zagen de NASA en ESA en IBM bij elkaar zitten."
    ])
    func ordinarySpeechIsNotTakenForACredit(_ line: String) {
        #expect(text(line) == line, "\(line)")
    }

    @Test func confidenceCountsOnlyTheSegmentsThatStay() {
        let transcript = AcousticTranscriptPolicy.transcript(from: [
            segment("Dank u wel.", logProbability: -0.4),
            segment("[BLANK_AUDIO]", logProbability: -0.01),
            segment("TV GELDERLAND 2021.", logProbability: -0.02)
        ])
        #expect(transcript.text == "Dank u wel.")
        #expect(abs(transcript.confidence - exp(-0.4)) < 0.0001)
        // A label that shares a segment with speech does not weigh in either.
        let mixed = AcousticTranscriptPolicy.transcript(from: [segment("Dank u wel [BLANK_AUDIO]", logProbability: -0.4), segment("Fijne dag", logProbability: -0.2)])
        #expect(abs(mixed.confidence - exp((-0.4 * 8 + -0.2 * 8) / 16)) < 0.0001)
    }

    @Test func combiningMarksAreNotLetters() {
        // Two accents on nothing are not a word.
        #expect(text("\u{0301}\u{0301}").isEmpty)
        #expect(text("ไม่").isEmpty == false)
    }

    @Test func aSegmentThatIsOnlyMusicOrCreditAmongSpeechIsDroppedAlone() {
        let transcript = AcousticTranscriptPolicy.transcript(from: [segment("Goedemorgen, kan ik u helpen?"), segment("♪"), segment("TV GELDERLAND 2021."), segment("Ja graag.")])
        #expect(transcript.text == "Goedemorgen, kan ik u helpen? Ja graag.")
    }
}
