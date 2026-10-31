import Foundation
import Testing
@testable import Marauders

@MainActor
struct ListeningLanguageTests {
    private func memo() -> DetectedLanguageMemo {
        DetectedLanguageMemo(defaults: UserDefaults(suiteName: "tests.\(UUID().uuidString)")!)
    }

    private func store(preferred: [String], region: String? = "US", explicit: ListeningLanguage? = nil,
                       memo: DetectedLanguageMemo? = nil) -> ListeningLanguageStore {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let store = ListeningLanguageStore(defaults: defaults, preferredLanguages: { preferred }, region: { region },
                                           memo: memo ?? self.memo())
        if let explicit { store.choose(explicit) }
        return store
    }

    private func clip(_ language: SpokenLanguageAssessment?, content: ClipAudioAssessment.Content = .speech) -> FeedVideo {
        FeedVideo(streamURL: URL(string: "https://example.com/a.mp4")!,
                  audioAssessment: ClipAudioAssessment(content: content, signal: .detected, spokenLanguage: language))
    }

    @Test func parsesLocaleIdentifiersIntoSupportedLanguages() {
        #expect(ListeningLanguage(identifier: "en-TH") == .english)
        #expect(ListeningLanguage(identifier: "th_TH") == .thai)
        #expect(ListeningLanguage(identifier: "zh-Hans-CN")?.code == "zh")
        #expect(ListeningLanguage(identifier: "zh-Hant-TW")?.code == "zh")
        #expect(ListeningLanguage(identifier: "no")?.code == "nb")
        #expect(ListeningLanguage(identifier: "nn-NO")?.code == "nb")
        #expect(ListeningLanguage(identifier: "pt-BR")?.code == "pt")
        #expect(ListeningLanguage(identifier: "xx") == nil)
        #expect(ListeningLanguage(identifier: "") == nil)
        #expect(ListeningLanguage(identifier: "yue-CN") == nil)
    }

    @Test func catalogMatchesTheBackendAllowList() {
        #expect(ListeningLanguage.all.count == 22)
        #expect(Set(ListeningLanguage.codes).count == ListeningLanguage.codes.count)
        for code in ListeningLanguage.codes { #expect(ListeningLanguage(identifier: code)?.code == code) }
    }

    @Test func namesAreLocalizedAndNeverEmpty() {
        let english = Locale(identifier: "en")
        #expect(ListeningLanguage.thai.displayName(in: english) == "Thai")
        #expect(ListeningLanguage.thai.displayName(in: Locale(identifier: "th")) == "ไทย")
        #expect(ListeningLanguage.spanish.nativeName == "Español")
        #expect(ListeningLanguage.spanish.sentenceName(in: Locale(identifier: "es")) == "español")
        for language in ListeningLanguage.all {
            #expect(!language.displayName(in: english).isEmpty)
            #expect(!language.nativeName.isEmpty)
        }
    }

    @Test func automaticChoiceSkipsTheLanguageAlreadySpokenInTheClip() {
        let viewer = store(preferred: ["en-TH", "th-TH"])
        #expect(viewer.effective == .english)
        #expect(viewer.supportedDeviceLanguages == [.english, .thai])
        #expect(viewer.targets(for: clip(.chosen("en"))) == [.thai])
        #expect(viewer.targets(for: clip(.chosen("es"))) == [.english, .thai])
        // Nobody knows this clip's language yet, so every language the viewer listens in is offered.
        #expect(viewer.targets(for: clip(nil)) == [.english, .thai])
    }

    @Test func anEnglishIPhoneInThailandWithThaiOnItsListReadsInThai() {
        // The owner's iPhone: English first, Thai second, region Thailand.
        let viewer = store(preferred: ["en-TH", "th-TH"], region: "TH")
        #expect(viewer.automatic == .thai)
        #expect(viewer.effective == .thai)
        #expect(CommentTranslation.source(for: Comment(body: "Thanks"), target: viewer.effective) == .known("en"))
        // Dubbing still offers every language the viewer listens in, in the device's order.
        #expect(viewer.possibleTargets == [.english, .thai])
    }

    @Test func theCountrysLanguageIsNotPickedWhenItIsNotOnTheIPhone() {
        // A visitor in Thailand who never added Thai.
        #expect(store(preferred: ["en-TH"], region: "TH").effective == .english)
        #expect(store(preferred: ["en-TH", "th-TH"], region: nil).effective == .english)
        #expect(store(preferred: ["en-US", "th-TH"], region: "US").effective == .english)
    }

    @Test func onlyAnEnglishFirstLanguageGivesWayToTheCountrys() {
        // A Thai iPhone abroad stays Thai, and a French one in Canada stays French.
        #expect(store(preferred: ["th-TH", "en-US"], region: "US").effective == .thai)
        #expect(store(preferred: ["fr-CA", "en-CA"], region: "CA").effective?.code == "fr")
        #expect(store(preferred: ["en-JP", "ja-JP"], region: "JP").effective?.code == "ja")
    }

    @Test func anExplicitChoiceStillWinsOverTheCountry() {
        #expect(store(preferred: ["en-TH", "th-TH"], region: "TH", explicit: .english).effective == .english)
    }

    @Test func explicitChoiceWinsAndIsNeverUsedForItsOwnLanguage() {
        let thaiViewer = store(preferred: ["en-US"], explicit: .thai)
        #expect(thaiViewer.targets(for: clip(.chosen("en"))) == [.thai])
        #expect(thaiViewer.targets(for: clip(.chosen("es"))) == [.thai])
        #expect(thaiViewer.targets(for: clip(nil)) == [.thai])
        #expect(thaiViewer.possibleTargets == [.thai])
        let englishViewer = store(preferred: ["th-TH"], explicit: .english)
        #expect(englishViewer.targets(for: clip(.chosen("en"))).isEmpty)
        #expect(englishViewer.targets(for: clip(.chosen("es"))) == [.english])
    }

    @Test func unsupportedDeviceLanguagesLeaveNoTargetUntilTheViewerChooses() {
        let viewer = store(preferred: ["bn-BD", "xx"])
        #expect(viewer.effective == nil)
        #expect(viewer.targets(for: clip(.chosen("en"))).isEmpty)
        viewer.choose(.thai)
        #expect(viewer.targets(for: clip(.chosen("en"))) == [.thai])
    }

    @Test func choiceIsSavedAndCanBeCleared() {
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let first = ListeningLanguageStore(defaults: defaults, preferredLanguages: { [] })
        #expect(first.explicit == nil)
        first.choose(.spanish)
        #expect(ListeningLanguageStore(defaults: defaults, preferredLanguages: { [] }).explicit == .spanish)
        first.choose(nil)
        #expect(first.explicit == nil)
        #expect(ListeningLanguageStore(defaults: defaults, preferredLanguages: { [] }).explicit == nil)
        defaults.set("not-a-language", forKey: "listeningLanguage")
        #expect(ListeningLanguageStore(defaults: defaults, preferredLanguages: { [] }).explicit == nil)
    }

    @Test func dubbingIsOfferedOnlyWhenItWouldChangeWhatTheViewerHears() {
        let english = clip(.chosen("en"))
        let spanish = clip(.chosen("es"))
        let french = clip(.chosen("fr"))
        let unknown = clip(nil)
        let music = clip(.chosen("es"), content: .music)

        let englishViewer = store(preferred: ["en-US"])
        #expect(!englishViewer.offersDubbing(for: english))
        #expect(englishViewer.offersDubbing(for: spanish))
        // Nobody knows the language, so the viewer's iPhone will find out when asked.
        #expect(englishViewer.offersDubbing(for: unknown))
        // A language we cannot dub from yet is a dead end, and music has nothing to dub.
        #expect(!englishViewer.offersDubbing(for: french))
        #expect(!englishViewer.offersDubbing(for: music))

        let thaiViewer = store(preferred: ["th-TH"])
        #expect(thaiViewer.offersDubbing(for: english))
        #expect(thaiViewer.offersDubbing(for: unknown))
        #expect(!thaiViewer.offersDubbing(for: music))
    }

    @Test func aDetectedLanguageIsRememberedAndHidesTheEntryWhenItIsTheViewersOwn() {
        let memo = memo()
        let viewer = store(preferred: ["en-US"], memo: memo)
        let video = clip(nil)
        #expect(viewer.offersDubbing(for: video))
        memo.remember("en", for: video.id)
        #expect(viewer.declaredCode(for: video) == "en")
        #expect(!viewer.offersDubbing(for: video))
        #expect(viewer.targets(for: video).isEmpty)
        // A declared language always wins over the memo.
        #expect(viewer.declaredCode(for: clip(.chosen("es"))) == "es")
        memo.remember("fr", for: video.id)
        #expect(!viewer.offersDubbing(for: video))
    }

    @Test func aDutchClipIsOfferedToEveryoneWhoDoesNotListenInDutch() {
        let dutch = clip(.chosen("nl"))
        let memoWithDutch = memo()
        #expect(store(preferred: ["th-TH"]).offersDubbing(for: dutch))
        #expect(store(preferred: ["en-US", "th-TH"]).targets(for: dutch) == [.english, .thai])
        // A Dutch viewer already understands it.
        #expect(!store(preferred: ["nl-NL"]).offersDubbing(for: dutch))
        // Detected on this phone earlier, the same holds without anything declared.
        let video = clip(nil)
        memoWithDutch.remember("nl", for: video.id)
        #expect(store(preferred: ["th-TH"], memo: memoWithDutch).offersDubbing(for: video))
        #expect(!store(preferred: ["nl-NL"], memo: memoWithDutch).offersDubbing(for: video))
    }

    @Test func viewersWithoutASupportedLanguageCanStillOpenThePicker() {
        let viewer = store(preferred: ["bn-BD"])
        #expect(viewer.offersDubbing(for: clip(.chosen("es"))))
        viewer.choose(.spanish)
        // They now listen in the clip's own language, so there is nothing to offer.
        #expect(!viewer.offersDubbing(for: clip(.chosen("es"))))
        #expect(viewer.offersDubbing(for: clip(.chosen("en"))))
    }

    @Test func voiceChoicePrefersTheUsualRegionThenQuality() {
        typealias C = SpeechVoiceCatalog.Candidate
        let english = [C(identifier: "b", language: "en-GB", quality: 3), C(identifier: "a", language: "en-US", quality: 1), C(identifier: "c", language: "en-AU", quality: 2)]
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: .english, among: english) == "en-US")
        // No conventional region for Dutch: the higher quality voice wins.
        let dutch = [C(identifier: "a", language: "nl-NL", quality: 1), C(identifier: "b", language: "nl-BE", quality: 3)]
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: ListeningLanguage(identifier: "nl")!, among: dutch) == "nl-BE")
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: .thai, among: english) == nil)
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: .thai, among: []) == nil)
        let norwegian = [C(identifier: "n", language: "no-NO", quality: 1)]
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: ListeningLanguage(identifier: "nb")!, among: norwegian) == "no-NO")
    }

    @Test func noveltyVoicesAreNeverChosen() {
        typealias C = SpeechVoiceCatalog.Candidate
        let voices = [
            C(identifier: "com.apple.eloquence.en-US.Rocko", language: "en-US", quality: 3),
            C(identifier: "com.apple.speech.synthesis.voice.Bells", language: "en-US", quality: 3)
        ]
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: .english, among: voices) == nil)
        let withReal = voices + [C(identifier: "com.apple.voice.compact.en-GB.Daniel", language: "en-GB", quality: 1)]
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: .english, among: withReal) == "en-GB")
    }

    @Test func thaiVoiceIsAvailableOnThisDevice() {
        // The system ships a Thai voice; dubbing into Thai must keep working as before.
        #expect(SpeechVoiceCatalog.bestLanguageTag(for: .thai, among: SpeechVoiceCatalog.candidates()) != nil)
    }

    @Test func translationPairsFollowTheListeningLanguages() {
        let english = Locale(identifier: "en")
        let thai = LanguageModel.translationModels(for: [.thai], locale: english)
        #expect(thai.map(\.id) == ["translation.en-th", "translation.es-th", "translation.nl-th"])
        #expect(thai.map(\.title) == ["English → Thai", "Spanish → Thai", "Dutch → Thai"])
        #expect(LanguageModel.translationModels(for: [.english], locale: english).map(\.id) == ["translation.es-en", "translation.nl-en"])
        #expect(LanguageModel.translationModels(for: [.english, .thai], locale: english).map(\.id)
                == ["translation.es-en", "translation.nl-en", "translation.en-th", "translation.es-th", "translation.nl-th"])
        #expect(LanguageModel.translationModels(for: []).isEmpty)
        #expect(LanguageModel.translationModels(for: [.spanish]).map(\.id) == ["translation.en-es", "translation.nl-es"])
    }

    @Test func pickerListsEveryLanguageSortedAndMarksTheSelection() async {
        struct Availability: ListeningLanguageAvailability {
            func unavailableLanguageCodes() async -> Set<String> { ["da"] }
        }
        let listening = store(preferred: ["en-US"], explicit: .thai)
        let picker = ListeningLanguagePickerViewModel(store: listening, availability: Availability())
        #expect(picker.rows.count == 22)
        #expect(picker.isChecking)
        await picker.refresh()
        #expect(!picker.isChecking)
        #expect(picker.rows.filter(\.isSelected).map(\.language) == [.thai])
        #expect(picker.rows.first { $0.language.code == "da" }?.isAvailable == false)
        let names = picker.rows.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func pickerRefusesUnavailableLanguagesAndSupportsAutomatic() async {
        struct Availability: ListeningLanguageAvailability {
            func unavailableLanguageCodes() async -> Set<String> { ["da"] }
        }
        let listening = store(preferred: ["en-US", "th-TH"])
        let picker = ListeningLanguagePickerViewModel(store: listening, availability: Availability())
        await picker.refresh()
        #expect(picker.isAutomatic)
        #expect(picker.automaticName == ListeningLanguage.english.displayName())
        #expect(!picker.choose(ListeningLanguage(identifier: "da")!))
        #expect(listening.explicit == nil)
        #expect(picker.choose(.spanish))
        #expect(!picker.isAutomatic)
        #expect(listening.explicit == .spanish)
        #expect(picker.summary == ListeningLanguage.spanish.displayName())
        picker.chooseAutomatic()
        #expect(listening.explicit == nil)
        #expect(picker.summary == String(localized: "Automatic · \(ListeningLanguage.english.displayName())"))
        #expect(ListeningLanguagePickerViewModel(store: store(preferred: ["xx"]), availability: Availability()).summary == String(localized: "Not set"))
    }

    @Test func aCheckThatFlagsEveryLanguageIsIgnored() async {
        struct EverythingUnavailable: ListeningLanguageAvailability {
            func unavailableLanguageCodes() async -> Set<String> { Set(ListeningLanguage.codes) }
        }
        let listening = store(preferred: ["en-US"])
        let picker = ListeningLanguagePickerViewModel(store: listening, availability: EverythingUnavailable())
        await picker.refresh()
        #expect(picker.rows.allSatisfy { $0.isAvailable })
        #expect(picker.choose(.thai))
        #expect(listening.explicit == .thai)
    }
}
