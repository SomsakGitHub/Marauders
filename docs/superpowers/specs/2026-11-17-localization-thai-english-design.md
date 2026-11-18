# Thai and English interface: design

Date: 2026-11-17
Status: approved by the owner on 2026-11-17 ("อนุมัติ") after a builder check (its three questions were settled as my
calls, marked in the design). Nothing has been built or committed.
Topic: Localization. This reverses the English-only decision of 2026-11-02 (fca9a87).
Size: a project. About 35 files change, the catalog will hold about 300 keys (234 found by a first extraction on
2026-11-17, about 70 more from the plain strings) of which about 170 have no Thai yet, and there is one Settings row, a
set of guard tests and the docs.

## Intent

The app has been English-only since 2026-11-02, when the owner dropped Thai and the string catalog ("ไม่ต้องทำ
Localizable"). The reasons on record were a Thai/English mix on screen and a chore on every commit. On 2026-11-17,
after a read-only audit, the owner asked for "Localization setting thai eng": Thai next to English, with a language
setting. Shown two ways to build the setting, the owner chose A ("แบบ A ตามเครื่อง"): the app follows the iPhone's
language, and a Settings row takes the viewer to iOS's own per-app language page.

The owner gave no further reason, so this design claims none. It aims at the reverse of the 2026-11-02 pain: a Thai
iPhone shows a Thai app, an English iPhone an English one, nothing in between, and adding a string later costs no
hand-merging.

## Goals

- English (the development language) and Thai are the app's two interface languages. iOS picks one from the iPhone's
  language list. A viewer can set the language for Marauders alone in iOS Settings > Marauders > Language, a row iOS
  shows once the app ships two languages.
- Settings has an "App language" row (first section) that shows the current interface language by its own name
  ("English", "ไทย") and opens the app's page in iOS Settings.
- With the app in Thai, every text the app composes is Thai: views, accessibility labels, alerts, status and error
  messages (also the roughly 75 that are plain strings today, see "How it works today") and the six permission texts
  of Info.plist. Language names inside sentences, country names, relative times and numbers follow through the
  system's formatters.
- A unit test fails when a catalog key has no Thai text, when a Thai text does not carry the same placeholders as its
  English key, or when the Info.plist catalog lacks Thai.
- The catalog is committed the way Xcode writes it, so a normal build leaves no diff.
- English is unchanged: the same words in the same places, so every test that pins an English string still passes.

## Non-goals

- No live language switch inside the app (approach B below). It would sit on top of this catalog and is not ruled out
  for later.
- No third language. Adding one later is one more language in the catalog.
- The Worker, its API, its error texts and what the app stores do not change. Two places show a Worker text as it
  comes (`VideoUploadForm.serverMessage` in `VideoUploadAPIClient` and in `BackgroundClipUploader+Completion`); those
  stay English.
- The listening (dubbing) language and the comment-translation language stay as they are and stay independent of the
  interface language.
- Units stay metric. Only the words around them are localized ("5 km", "450 m away"). Miles for US and UK viewers is a
  separate product decision (the radius presets would need new values).
- Developer-only text stays English: the debug log viewer, test sign-in, configuration and assertion messages,
  UI-test fixtures, `AppLog` lines.
- App Store Connect listing text, and any TestFlight build (the owner starts Jenkins), are outside this work.
- No commit and no push without the owner's word.

## Anti-goals (a failure even if everything compiles)

- A Thai screen with an English sentence in it, or the reverse.
- An English string that changes. The tests and the owner's screenshots pin them.
- Thai text that is clipped or overlaps. Thai has stacked marks and no spaces between words, so the main screens are
  looked at in Thai, also at a large Dynamic Type size.
- A catalog that shows a diff after every build.
- A translated string sent to the Worker, or stored where it is later read in another language (the three stored
  upload-failure texts are the accepted exception).

## How it works today

- `knownRegions = (en, Base)`, no string catalog, no Info.plist strings. The project uses synchronized folders, so a
  file placed under `Marauders-ios/Marauders/` needs no project edit. The six `INFOPLIST_KEY_NS...` usage texts live in
  build settings.
- Strings Xcode extracts: about 225 literals in views and modifiers (Text, Button, Label, navigation titles, alerts,
  accessibility labels) and 53 or more `String(localized:)` calls, some split over two lines. The 2026-11-02 catalog
  (137 keys, all with Thai) is in git at `fca9a87^`; about 115 of today's literals match it.
- Strings Xcode cannot extract because they are plain `String`s: about 75 distinct texts in about 35 files that the
  viewer still sees. They are the `errorDescription` of API and Domain errors ("Sign in required", "Server responded
  with status 500", "Upload failed ..."), the failure texts of `UploadRecord`, status and error messages of view
  models (sign-in and location gate, upload, location picker, follow lists, profile, friend sharing), `NearMeRadius`
  ("5 km", "No clips within 5 km"), `MapClipProximity` ("450 m away") and the default prompt of `MapSearchBar`. On a
  Thai screen these would stay English, the same kind of mix as in 2026-11. A conditional of two literals inside
  `Text`, `Button` or `Label` is extracted (checked with a small probe on 2026-11-17: the compiler picks the
  `LocalizedStringKey` initializer), so the four such conditionals in the views are fine. A conditional that mixes a
  literal with a `String` variable, `?? "literal"` and `String(format:)` are not extracted. The count is a lower bound
  until the extraction build and the scan under "Done means" have run.
- The session package `MaraudersAuth` has six English error texts for the viewer (`AuthAPIError` and the sign-in use
  case) and one developer-only (`AuthRoute`). `AuthViewModel.userFacingMessage(for:)` shows any `LocalizedError`
  description as it is.
- `ListeningLanguage.interfaceLocale` follows `Bundle.main.preferredLocalizations`. `CountryCatalog`, the comment times
  and the compact numbers use the current locale. They need no change.
- UI tests launch with `-AppleLanguages (en) -AppleLocale en_US`.

## Approaches

- **A (chosen by the owner).** Follow the iPhone; one Settings row opens iOS's per-app language page. iOS switches the
  whole process, so strings, formatters and system-drawn text change together. The app restarts when the viewer
  changes the language. Apple's own guidance (a developer-support answer on the Apple forums) is that an app cannot
  change its own language and should send the viewer to its page in Settings, which is what A does.
- **B.** A live switch inside the app. iOS has no public API for it. It needs `.environment(\.locale)` for SwiftUI
  text, a bundle override for every `String(localized:)`, the locale injected into each formatter, and still leaves
  system-drawn text and the permission prompts in the iPhone's language. Texts that view models store would stay
  stale until their next event. Considerably more work than A, with a new class of bugs. It builds on A's catalog, so
  doing A first loses nothing.
- **C.** Write `AppleLanguages` and ask for a restart. Undocumented; rejected.

## Design

Items marked (my call) are mine, not the owner's.

1. **Catalog.** Restore `Marauders-ios/Marauders/Resources/Localizable.xcstrings` (source `en`, plus `th`), add
   `InfoPlist.xcstrings` with Thai for the six usage texts, and add `th` to `knownRegions`. The English text is the key
   and the English value. Debug-only keys are marked "don't translate" (my call).
2. **Make the plain strings localizable.** Each plain user-facing text becomes `String(localized: "...")` with the
   identical English words (interpolations become placeholders), so English cannot change. A `LocalizedError` keeps its
   type and localizes its descriptions in place. Developer-only texts stay as they are. The package keeps its English
   texts; `AuthViewModel.userFacingMessage(for:)` maps `AuthAPIError` and the sign-in use-case error to localized app
   strings and falls back to a localized generic message (my call, so the package needs no resources). The dead Thai
   sentences of `ClipAudioAssessment.message`, read only by two test assertions, are deleted with those assertions
   (my call), so no Thai literal is left in the app's Swift sources. `UploadFailure` stores text in three cases
   (`.connection`, `.rejected`, `.serverError`, saved with the upload record): the fallback `Upload failed (status N)`
   is localized where it is made, and a stored text keeps the language it was made in (my call; storing the status code
   instead would change the record format, and the Worker's own text stays English anyway).
3. **Thai.** I write the Thai and reuse the vocabulary and register of the 2026-11-02 catalog so the wording stays
   consistent (my call; that catalog is neutral in tone: "คุณ" for you, no ครับ/ค่ะ).
   The owner reviews the new strings as a table, plus screenshots, before anything is committed.
4. **Settings row.** First section of `SettingsView`: "App language" with a globe icon. The value is the own name of the
   current interface language. Tapping it opens `UIApplication.openSettingsURLString` through `openURL`, the way
   "Allow location access Always" does. A footer says the app restarts when the language changes. Accessibility id
   `settings.appLanguage`. The iOS 27.2 SDK has no link straight to the language page (only
   `openSettingsURLString` and two other settings links), so the row opens the app's page. Info.plist gets
   `UIPrefersShowingLanguageSettings` = YES, through a small `Marauders-ios/Config/Info-Additions.plist` that
   `INFOPLIST_FILE` merges into the generated Info.plist (Xcode ignores the build setting
   `INFOPLIST_KEY_UIPrefersShowingLanguageSettings`; both were tried on 2026-11-17), because forum reports say iOS
   otherwise hides the Language row on a phone with only one preferred language (my call; I found no Apple
   documentation for the key, so verify on the simulator).
5. **Guard tests (my call).** A unit test reads the committed catalogs (path from `#filePath`) and fails for a key
   without Thai, for a placeholder mismatch between English and Thai, and for a missing Info.plist Thai text.
   "Don't translate" keys are exempt.
6. **Xcode workflow.** The extraction build settings stay on. In Xcode's window a new string appears in the catalog at
   the next build. `xcodebuild` does not write the catalog (tried on 2026-11-17), so on the command line
   `xcrun xcstringstool sync Localizable.xcstrings --stringsdata <each .stringsdata of the build>` does it, in the same
   format; the file must be named `Localizable.xcstrings`, because the table name comes from the file name. The guard
   test fails until a new string's Thai is filled in, and the file is committed as Xcode wrote it.
7. **Tests and language (my call).** The unit tests run hosted in the app and pin no language today, so they follow
   the language of the simulator or phone, and at least 17 assertions pin English app texts ("Invalid account", "Sign
   in required", "Upload complete — opening feed", ...). The shared scheme's TestAction gets its own launch arguments
   `-AppleLanguages (en) -AppleLocale en_US` (`shouldUseLaunchSchemeArgsEnv` becomes NO; the Run action has no
   arguments today, so nothing else changes), and the pin is checked on a simulator whose language is Thai (tried on
   2026-11-17 with a probe test: with the arguments the test host runs in English, without them in Thai; the arguments
   reach the unit-test host only, not an app that a UI test launches). The existing UI
   tests stay English through their launch arguments. A small Thai set launches with
   `-AppleLanguages (th) -AppleLocale th_TH` and checks the tab names, the Settings row and one error screen.
8. **Look at it.** The main screens in Thai on the simulator at the default and at a large Dynamic Type size; fix what
   clips.
9. **Docs.** README, `deployment/AI_DUBBING.md` (the "English only" sentence), ARCHITECTURE.md (a Localization section:
   where strings live, how to add one, the plain-string rule, the guard tests) and the memory notes.

## What is left to the builder

The Thai wording of each string; which debug-only keys are marked "don't translate"; the exact footer texts; the
file-by-file conversion; how to split commits when the owner asks (proposed: 1. strings made localizable, English
unchanged; 2. catalog, Thai, project setting, guard tests; 3. Settings row, UI tests, docs).

## Risks to check while building

- iOS's per-app language may change `Locale.preferredLanguages` for the app, so the "Automatic" listening language
  could follow the app language. That would be expected, not a bug; check the picker's summary text.
- Stored texts: the three `UploadFailure` cases named in the design are the ones found. Look for others while
  converting (`UserDefaults`, memos, caches).
- The per-app Language row appears only when iOS sees two localizations in the built app: confirm that both language
  folders are in the bundle (`en.lproj`, `th.lproj`), whether the Info.plist needs `CFBundleLocalizations`, and that
  the row really shows in the simulator.
- Thai grammar around language names: "AI audio in Thai" needs the word "ภาษา" before the name.

## Done means

- The existing tests pass on the simulator (unit; UI 51 of 52 with the known simulator-only red) together with the new
  ones, and the unit tests also pass on a simulator whose language is Thai, which shows the scheme's English pin
  holds.
- The plain-string scan reports nothing outside its allowlist (my call). It is a script,
  `Scripts/find-plain-strings.py`, committed with its allowlist `Scripts/plain-strings-allowlist.txt` and run by hand
  before a TestFlight build; it is not part of the build. It reports a single-line literal that reads like text (a
  sentence that starts with a capital letter or a placeholder, or one capitalised word), is not an argument of a
  localizable API (`Text`, `Button`, `Label`, `String(localized:)` and the like) and is not logging, an assertion, an
  identifier or a URL. A first run of a prototype on the unchanged tree found 117 such literals in 42 files; about 15
  of them are developer-only and go into the allowlist. Wiring it into the Debug
  build as warnings, the way the layer checker is wired, is possible later.
- The main screens were looked at in Thai, at the default and at a large Dynamic Type size, and the owner has seen the
  table of Thai texts and the screenshots.
- An unsigned Release archive builds.
- Nothing was run on a phone (the owner's rule), and nothing is committed or pushed until the owner says.
