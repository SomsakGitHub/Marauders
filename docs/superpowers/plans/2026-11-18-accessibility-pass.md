# Accessibility Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix what a simulator can prove about the app's accessibility (a feed caption that runs under the action rail, four unreadable-text defects, text cut or covered at the largest sizes, an upload status that rests on colour) and add the tests that keep it fixed.

**Architecture:** The feed's caption and action rail become two children of one bottom `HStack`, so they cannot overlap at any text size or language; the caption is clamped to 3 lines (2 at accessibility sizes) with a "more" / "less" button. The other defects are one- to ten-line edits in the view that draws them. The guard is a new UI-test file that runs Apple's accessibility audit (three stable audit types) on eight screens and tests the caption layout, plus two small unit-test files for pure logic (the caption clamp, the avatar palettes).

**Tech Stack:** SwiftUI (every target iOS 27.0), Swift Testing (unit), XCTest / `XCUIApplication.performAccessibilityAudit` (UI), `Localizable.xcstrings`.

**Spec:** `docs/superpowers/specs/2026-11-18-accessibility-pass-design.md` (approved by the owner on 2026-11-18; item 7 amended afterwards, the amendment is marked in it). Read it first: this plan carries the decisions the implementer needs, the spec carries the reasons.

## Global Constraints

- Every target is iOS 27.0. SwiftUI with one UIKit pager (`VerticalFeedPagingView`), which this pass does not touch.
- **Edit in the main checkout** (`/Users/tiscomacnb2486/Desktop/Marauders`); **build and test only from the scratch mirror** (see "Running things"). Never edit, stage, format or commit `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` (the owner's uncommitted edit) or the untracked `docs/superpowers/plans/2026-11-17-session-core-package.md` and `docs/superpowers/specs/2026-11-17-session-core-module-design.md`.
- Tests run only on the iOS 27.2 simulator `902C645A-22D9-47F3-86B0-3E4623B6B2A9`, never on the phone.
- **No step commits or pushes.** Commit and push happen only on the owner's explicit order, and then only the paths this plan touches.
- New texts are localizable and translated into Thai in the same change: exactly two, `more` → `ดูเพิ่ม` and `less` → `ย่อ`, added **by hand** to `Marauders/Resources/Localizable.xcstrings` (`xcstringstool sync` would re-sort the whole file). `LocalizationCatalogTests` and `StringCatalogLayoutTests` stay green.
- Presentation only, plus the UI-test fixture flags in `Data/Repositories/UITestFeedRepository.swift`; the layer checker gets no new exception (`Scripts/layer-exceptions.txt` unchanged).
- Existing accessibility identifiers keep their names; the only additions are `feed.caption` and `feed.captionToggle`.
- Paging, tap to play and double tap to like do not change. A caption that fits keeps today's type (`.subheadline`) and place. No look change beyond the ones the spec marks **Visible**.
- Numbers from the spec: caption at most **3 lines (2 at accessibility sizes)**; opened caption block at most about **40%** of the screen height; rail text capped at **`xxxLarge`**; avatar stops a **40% shade** of the light-appearance system colours; text we draw at least **4.5:1** (`1.05 / (L + 0.05)` against white; `.superpowers/accessibility-audit/contrast.py`).
- Left alone on purpose (spec Non-goals): the accent colour, the brand red under white text, the heart telling liked from not liked by colour alone, system-drawn controls, the locate button's arrow (same `.primary` cause as Share location, not flagged), the grey `.secondary` captions under comments ("Translated on this iPhone from…").

## Review Focus

The inputs the spec implies and no spec-derived test covers, most likely first, each pinned by a test in the task that owns the code:

1. **A clip with no caption** (captions are optional, so most real clips may have none): the rail must stay on the right edge. An `HStack` with nothing on its left would slide it to the left. → `testAClipWithoutACaptionKeepsTheRailOnTheRight` (Task 1).
2. **A caption exactly 3 lines tall, or taller only by rounding noise**: no "more" button. → `FeedCaptionClampTests.aCaptionThatFitsIsNeverCut`, `roundingNoiseIsNotACut` (Task 1).
3. **Swiping to the next clip while a caption is open**: the next clip starts closed. → `testAnOpenCaptionClosesWhenTheClipChanges` (Task 1).
4. **A tap or double tap on the collapsed caption**: it must reach the pager (like by double tap), not be swallowed by the new text. → `testADoubleTapOverACollapsedCaptionStillLikesTheClip` (Task 1).
5. **A handle that is nil, empty, an emoji or 10,000 characters long**: still gets a palette (no trap, index 0 to 5), and every other handle keeps its pair. → `AvatarPaletteTests.oddHandlesStillGetAPalette`, `aHandleKeepsItsPalette` (Task 4).

## Running things

All commands are run from the repository root. `.superpowers/accessibility-audit/` is git-ignored and holds the helpers and the "before" evidence (screenshots and audit logs of the unchanged app).

- **Run** a test = `bash .superpowers/accessibility-audit/mirror.sh && bash .superpowers/accessibility-audit/run.sh <log-name> <test id> [<test id>…]`. `mirror.sh` copies `Marauders-ios/` into the scratchpad with HEAD's `RetryingHTTPClient.swift`; `run.sh` runs `xcodebuild test` on the simulator, one `-only-testing:` per id, and **exits 1 when no test ran** (a filter that matches nothing otherwise says `TEST SUCCEEDED`). Ids look like `MaraudersTests/FeedCaptionClampTests` or `MaraudersUITests/MaraudersAccessibilityUITests/testAShortCaptionHasNoMoreButton`. The first run after a reboot is a clean build (about 100 s). Read the `Test run with N tests` / `Executed N tests` line before believing a green run.
- **Look at it** = `bash .superpowers/accessibility-audit/mirror.sh && bash .superpowers/accessibility-audit/shots.sh shots MaraudersUITests/ZZShotsThrowaway/<test> …`, then open the PNGs in `$SCR/a11y/` (the session's scratchpad folder) with the Read tool. `shots.sh` copies the throwaway harness (`harness/ZZ*.swift`: Apple's audit per screen, `ZZShotsThrowaway` for named feed screenshots) into the mirror only, never into the repository. The harness has these shots: `testLong_std`, `testLong_ax2`, `testLong_ax5`, `testLongOpen_std`, `testLongOpen_ax5`, `testLongThai_ax5`, `testShort_std`, `testShort_ax5`, `testNone_std`; the audit class `ZZAccessibilityAuditThrowaway` has `test<Screen>_std` / `_ax5` for feed, comments, map, upload, profile, settings, publicProfile, clipPlayer, followList, signInSheet and logs every issue to `$SCR/a11y/audit.log`. `$SCR` is the scratchpad folder the scripts default to (set the `SCR` environment variable to use another).
- **Count**: `grep -rho '@Test' Marauders-ios/MaraudersTests --include='*.swift' | wc -l` and `grep -rl '@Test' Marauders-ios/MaraudersTests --include='*.swift' | wc -l` (1326 and 113 before this pass).
- New files need no project edit: the targets use synchronized folders.

## File Structure

Create:
- `Marauders-ios/MaraudersTests/FeedCaptionClampTests.swift`: the caption clamp's pure rules (Task 1).
- `Marauders-ios/MaraudersTests/AvatarPaletteTests.swift`: palette contrast, the six pairs, the handle mapping (Task 4).
- `Marauders-ios/MaraudersUITests/MaraudersAccessibilityUITests.swift`: caption layout tests (Tasks 1, 2) and the audit guard (Task 8). One class, one launch helper, no shared state with `MaraudersUITests.swift`.

Modify (all under `Marauders-ios/`): `Marauders/Data/Repositories/UITestFeedRepository.swift`, `Marauders/Presentation/Feed/Playback/FeedClipCaptionOverlay.swift`, `Marauders/Presentation/Feed/FeedClipActionRail.swift`, `Marauders/Presentation/Feed/VideoFeedView.swift`, `Marauders/Presentation/Common/ClipPlayerView.swift`, `Marauders/Presentation/Common/AvatarView.swift`, `Marauders/Presentation/Map/MapView.swift`, `Marauders/Presentation/Comments/CommentRow.swift`, `Marauders/Presentation/Debug/CopyableStatusBanner.swift`, `Marauders/Presentation/Upload/UploadVideoView.swift`, `Marauders/Resources/Localizable.xcstrings`, `MaraudersUITests/MaraudersThaiUITests.swift`; and `ARCHITECTURE.md` at the repository root (Task 9).

---

### Task 1: The caption and the rail share one row

**Files:**
- Create: `Marauders-ios/MaraudersTests/FeedCaptionClampTests.swift`, `Marauders-ios/MaraudersUITests/MaraudersAccessibilityUITests.swift`
- Modify: `Data/Repositories/UITestFeedRepository.swift`, `Presentation/Feed/Playback/FeedClipCaptionOverlay.swift`, `Presentation/Feed/FeedClipActionRail.swift`, `Presentation/Feed/VideoFeedView.swift` (`feedScroll`), `Resources/Localizable.xcstrings`

**Interfaces:**
- Produces, in `FeedClipCaptionOverlay.swift` (internal):
  - `enum FeedCaptionClamp { static func lineLimit(accessibilitySize: Bool) -> Int` (3, or 2 when true) `; static func isCut(fullHeight: CGFloat, clampedHeight: CGFloat) -> Bool }` (true only when `fullHeight - clampedHeight > 1`).
  - `struct FeedCaptionScrim: View`, `init()`: today's gradient (`.black.opacity(0.0)` to `.black.opacity(0.55)`, top to bottom, `ignoresSafeArea(edges: .bottom)`, no touches, hidden from VoiceOver), now its own full-width layer.
  - `struct FeedClipCaptionOverlay: View`, `init(clip: FeedVideo, maxOpenHeight: CGFloat)`: the caption block only (no gradient, no full-screen frame).
- Produces launch flags (`UITestFeedRepository`): `UITEST_LONG_CAPTION` gives every clip of the fixture feed (the default clip and the streaming ones) the caption `String(repeating: "Walking the old town at sunrise, with the market stalls opening one by one. ", count: 6) + "The end."` (464 characters, under the Worker's 500); `UITEST_NO_CAPTION` gives every clip `caption: nil` (and wins when both are given). Without them the fixture is unchanged (`UI test clip`, `Streaming test clip N`).
- Produces identifiers `feed.caption` (the caption `Text`) and `feed.captionToggle` (the button).
- Consumes: `FeedClipActionRail(...)` as it is, except that it loses its own full-screen frame.

- [ ] **Step 1: Write the failing unit tests** in `FeedCaptionClampTests.swift` (Swift Testing, style of `FeedTapSequenceTests.swift`): `lineLimitIsThreeAtNormalSizesAndTwoAtAccessibilitySizes` (`lineLimit(accessibilitySize: false) == 3`, `true` gives `2`); `aCaptionThatFitsIsNeverCut` (`isCut(fullHeight: 51, clampedHeight: 51) == false`); `roundingNoiseIsNotACut` (`51.4` against `51`, and exactly `52` against `51`, both `false`); `moreThanOnePointTallerIsCut` (`71` against `51` is `true`).
- [ ] **Step 2: Run** `MaraudersTests/FeedCaptionClampTests`. Expected: build error, `FeedCaptionClamp` not found.
- [ ] **Step 3: Implement `FeedCaptionClamp`** in `FeedClipCaptionOverlay.swift` (above). Run again: `Test run with 4 tests`, passed.
- [ ] **Step 4: Fixture flags** in `UITestFeedRepository.fetchFeed(limit:cursor:country:)`, read like the existing `UITEST_STREAMING_FEED` (`ProcessInfo.processInfo.arguments.contains`). Add the identifier `.accessibilityIdentifier("feed.caption")` to the caption `Text` of the **old** overlay, so the next tests can run against the old layout (no behaviour change).
- [ ] **Step 5: Write the failing UI tests** in `MaraudersAccessibilityUITests.swift`: `final class MaraudersAccessibilityUITests: XCTestCase` with `continueAfterFailure = false`; a launch helper `launch(_ flags: [String] = [], textSize: String? = nil) -> XCUIApplication` (arguments `["UITEST", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + flags` plus `-UIPreferredContentSizeCategoryName <textSize>`, `launchEnvironment["UITEST"] = "1"`); `largestText = "UICTContentSizeCategoryAccessibilityXXXL"`; private `waitUntilLabel(_:is:timeout:)` and `waitUntilHittable(_:timeout:)` as in `MaraudersUITests.swift` (they are private there); `railLeftEdge(_ app:) -> CGFloat` = the smallest `frame.minX` among the existing `feed.like`, `feed.comments`, `feed.avatar` buttons. Tests (waits are `waitForExistence(timeout: 15)`):
  - `testALongCaptionStaysLeftOfTheRail` and `…AtTheLargestTextSize` (`launch(["UITEST_LONG_CAPTION"])`, the second with `textSize: largestText`): `app.staticTexts["feed.caption"].frame.maxX < railLeftEdge(app)`; the caption's `label` `hasSuffix("The end.")` (VoiceOver reads all of it although it is cut).
  - `testMoreOpensTheWholeCaptionAndLessClosesIt`: `app.buttons["feed.captionToggle"]` label `"more"`; remember the caption's `frame.height`; tap; label becomes `"less"`; height grows and stays `<= feed.root.frame.height * 0.45`; tap; label `"more"`, height back within 1 pt.
  - `testAShortCaptionHasNoMoreButton`: `launch()`; `feed.caption` exists; `feed.captionToggle` does not.
  - `testAClipWithoutACaptionKeepsTheRailOnTheRight` (`UITEST_NO_CAPTION`): no `feed.caption`; `feed.like.frame.midX > feed.root.frame.midX`; the rail's largest `maxX` is `> feed.root.frame.maxX - 40`.
  - `testAnOpenCaptionClosesWhenTheClipChanges` (`["UITEST_STREAMING_FEED", "UITEST_LONG_CAPTION"]`): open it (`"less"`), `feed.root.swipeUp(velocity: .fast)`, `waitUntilLabel(toggle, is: "more")`. The clips need not play, so no network is needed for the swipe.
  - `testADoubleTapOverACollapsedCaptionStillLikesTheClip` (`UITEST_LONG_CAPTION`): double tap `feed.caption.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))`; `waitUntilLabel(feed.like, is: "Unlike")`.
- [ ] **Step 6: Run** `MaraudersUITests/MaraudersAccessibilityUITests`. Expected on the old layout: red are the two overlap tests (the caption's right edge is under the rail), `testMoreOpens…` and `testAnOpenCaption…` (no toggle); green are the short-caption, no-caption and double-tap tests (they guard the new layout). A different red means the test is wrong: fix it before going on.
- [ ] **Step 7: Implement the row.**
  - `FeedClipCaptionOverlay`: nothing visible when `clip.caption` is nil or blank, but the view still takes `frame(maxWidth: .infinity, alignment: .leading)` so the rail keeps the right edge; padding `.leading` 20 and `.bottom` 28 as today. The caption is `Text` with `.font(.subheadline)`, white, a soft shadow (`.black.opacity(0.3)`, radius 2, y 1, as the heart's), `.allowsHitTesting(false)` **on the text only**, id `feed.caption`. Collapsed: `lineLimit(FeedCaptionClamp.lineLimit(accessibilitySize: dynamicTypeSize.isAccessibilitySize))`. Cut detection: `isCut(fullHeight:clampedHeight:)` fed by two `onGeometryChange` readings, the clamped `Text` and a hidden copy in its `.background` (`.fixedSize(horizontal: false, vertical: true)`, `.hidden()`, `.accessibilityHidden(true)`). The toggle is a `Button` under the text, visible while `isCut || isOpen`, label `Text("more")` / `Text("less")` (its own visible word, no `accessibilityLabel`), `.font(.subheadline.weight(.semibold))`, white, id `feed.captionToggle`, hit area at least 44 x 44 pt (`.frame(minWidth: 44, minHeight: 44, alignment: .leading)`, `.contentShape(Rectangle())`; the Thai word is narrow), `withAnimation(.snappy)` on toggle. Open: the whole caption in a block as tall as it needs up to `maxOpenHeight`, then scrolling (`ViewThatFits(in: .vertical)` with the plain text first and a `ScrollView` second, inside `.frame(maxHeight: maxOpenHeight)`).
  - `FeedClipActionRail`: delete `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)`; keep both paddings and the `onChange`.
  - `VideoFeedView.feedScroll`, inside `if let video = currentVideo`: `FeedCaptionScrim()` framed to the geometry (as the overlay was), then the row `HStack(alignment: .bottom, spacing: 12) { FeedClipCaptionOverlay(clip: video, maxOpenHeight: geometry.size.height * 0.4).id(video.id); FeedClipActionRail(…unchanged arguments…) }` framed `width: geometry.size.width, height: geometry.size.height, alignment: .bottom`. The `.id(video.id)` is what closes the caption for a new clip. `playbackOverlay` stays where it is (Task 2 moves it).
- [ ] **Step 8: Catalog.** Insert `more` (`ดูเพิ่ม`) and `less` (`ย่อ`) into `Localizable.xcstrings`, state `translated`, in the entry layout of `Share location` (two-space indent, `"key" : {`). The file is in the Xcode editor's key order (case ignored): `less` goes between `Languages` and `Letters, numbers, dots and underscores.`, `more` between `Models run on this device…` and `Names the language of a clip…` (`StringCatalogLayoutTests` fails when an order is wrong).
- [ ] **Step 9: Run** `MaraudersUITests/MaraudersAccessibilityUITests`, `MaraudersTests/FeedCaptionClampTests`, `MaraudersTests/LocalizationCatalogTests`, `MaraudersTests/StringCatalogLayoutTests` and the existing UI tests that find or touch the caption area (`MaraudersUITests/MaraudersUITests/testStreamingFeedForwardAndReverseSwipes`, `…/testStreamingShortDragsReturnToSameClipInBothDirections`, `…/testDoubleTapOnTheClipLikesItAndNeverTakesTheLikeBack`). Expected: all green. If the two streaming tests stop finding `app.staticTexts["Streaming test clip 0"]` because of the new identifier, change their lookup to `app.staticTexts["feed.caption"]` plus a label check and say so in the report.
- [ ] **Step 10: Look at it** (`testLong_std`, `testLong_ax2`, `testLong_ax5`, `testLongOpen_std`, `testLongThai_ax5`, `testShort_std`, `testNone_std`) and compare with `.superpowers/accessibility-audit/before/feed/feedLong-std.png` and `feedLong-ax2.png`. Judge: nothing under the rail, "more" readable, the opened block stays in the lower 40%, a short caption looks as before. If an opened block is unreadable over a bright frame, give only the opened block a black 35% rounded backing and say so in the hand-off (a **Visible** addition the owner can veto).

### Task 2: The rail at large text sizes, the failure card under the row

**Files:**
- Modify: `Presentation/Feed/FeedClipActionRail.swift`, `Presentation/Feed/VideoFeedView.swift` (`feedScroll`)
- Test: `MaraudersUITests/MaraudersAccessibilityUITests.swift`

**Interfaces:**
- Consumes: Task 1's row and the `largestText` constant and `launch(_:textSize:)` helper.
- Produces: nothing new.

- [ ] **Step 1: Write the failing UI tests.**
  - `testTheRailStopsGrowingAtTheLargestNonAccessibilitySize`: launch with `textSize: "UICTContentSizeCategoryXXXL"`, record `feed.comments.frame.size` and `feed.like.frame.size`; terminate; launch with `textSize: largestText`; the sizes equal the first ones within 1 pt.
  - `testLikeAndCommentsStayReachableUnderTheFailureCardAtTheLargestTextSize`: `launch([], textSize: largestText)`; the fake clip cannot play, so `app.buttons["Play Again"]` appears (wait 30 s); then `waitUntilHittable` for `feed.like`, `feed.comments`, `feed.avatar` and `Play Again`.
- [ ] **Step 2: Run** them. Expected red: the rail is larger at the largest size, and the card covers Like and Comments.
- [ ] **Step 3: Rail.** `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` on the rail's outer `VStack`; on each button `.accessibilityShowsLargeContentViewer { Label(<the button's existing label text>, systemImage: <its icon>) }` (heart.fill with `Like`/`Unlike`, `bubble.right` with `Comments`, `waveform` with `Choose audio`, `person.crop.circle` with `Open \(handle) profile`: all existing catalog keys); the count and label `Text`s of Like, Comments and Choose audio get the icons' shadow (`.black.opacity(0.3)`, radius 2, y 1).
- [ ] **Step 4: Failure card.** In `feedScroll`, draw `playbackOverlay` before the row (after the scrim) so the rail and caption are above it.
- [ ] **Step 5: Run** `MaraudersUITests/MaraudersAccessibilityUITests` whole: green. **Look at it** (`testLong_ax5`, `testShort_ax5`, `testLong_ax2`): the rail small, labels readable with their shadow, the card reachable. Compare `before/feed/feedLong-ax2.png`.

### Task 3: The clip player's audio button wraps

**Files:**
- Modify: `Presentation/Common/ClipPlayerView.swift` (`bottomBar`, the `clip.chooseAudio` button)

**Interfaces:** none.

No permanent test: `XCUIElement.label` returns the whole title even when it is drawn cut, and the guard leaves the `textClipped` audit out (39 of 120 reports were false). The proof is the throwaway audit and a screenshot.

- [ ] **Step 1: Baseline.** The "before" is `.superpowers/accessibility-audit/before/dark/clipPlayer-ax5.png` and the `textClipped` line for it in `before/logs/audit-dark.log`.
- [ ] **Step 2: Change** the button's `Label(audioButtonTitle, systemImage: "waveform")` so the title wraps (up to the lines it needs) and the button still fills the width; at the default size it looks as before (one line). Pick the modifier that works on screen (`.fixedSize(horizontal: false, vertical: true)`, `.multilineTextAlignment(.center)`). If "Open in Google Maps" or "Play in Feed" are also cut in the AX5 screenshot, give them the same fix.
- [ ] **Step 3: Verify** with `ZZAccessibilityAuditThrowaway/testClipPlayer_std` and `testClipPlayer_ax5` (Look at it): at AX5 the whole "Original audio · Choose audio" is on screen, and `$SCR/a11y/audit.log` no longer has a `textClipped` line for the button.

### Task 4: Avatar placeholder palettes

**Files:**
- Create: `Marauders-ios/MaraudersTests/AvatarPaletteTests.swift`
- Modify: `Presentation/Common/AvatarView.swift`

**Interfaces:**
- Produces (internal): `AvatarView.palettes: [[Color]]` (today `private static let`) and `static func paletteIndex(for handle: String?) -> Int`, the seed code that `gradient(for:)` has today, moved out unchanged: `seed = scalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffffff }`, index `seed % palettes.count`, `nil` gives seed 0.

- [ ] **Step 1: Write the failing tests** in `AvatarPaletteTests.swift` (Swift Testing; resolve a `Color` with `UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))` and `getRed`, WCAG ratio against white as in `.superpowers/accessibility-audit/avatar_contrast.py`):
  - `everyGradientStopReachesFourPointFiveToOneInLightAndDark`: each stop of each palette, for `.light` and `.dark`, `ratio >= 4.5` (message names the palette and stop).
  - `thePalettesAreStillSix`: 6 palettes of 2 stops.
  - `aHandleKeepsItsPalette` (parameterised on handle and index): `@a` 5, `@b` 0, `@c` 1, `@d` 2, `@g` 5, `@bob` 5, `@carol` 5, `@traveler` 3, `@marauders` 4, `@stream0` 2, `@stream1` 3, `@stream3` 5, `@alice` 4 (computed from today's seed, so nobody's pair moves).
  - `oddHandlesStillGetAPalette`: `nil` and `""` give 0; `"@😀"`, `"ก"` and `"@" + String(repeating: "x", count: 10_000)` give an index in `0..<6`.
- [ ] **Step 2: Run** `MaraudersTests/AvatarPaletteTests`. Expected: build error (`palettes` and `paletteIndex` not accessible).
- [ ] **Step 3: Implement.** Palettes become **fixed** sRGB colours (the same in both appearances), each 60% of the system colour's light-appearance value (`Color(red: r / 255, green: g / 255, blue: b / 255)`): orange `(153, 89, 0)`, pink `(153, 27, 51)`, blue `(0, 73, 153)`, purple `(105, 49, 133)`, teal `(29, 106, 119)`, indigo `(53, 52, 128)`, red `(153, 35, 29)`, green `(31, 119, 53)`. The six pairs, in this order: orange→pink, blue→purple, teal→indigo, pink→red, green→blue, **purple→pink** (the last replaces yellow→orange). The worst stop is orange at 5.55:1. Everything else in `AvatarView` (ring, initial, glyph) stays.
- [ ] **Step 4: Run** `MaraudersTests/AvatarPaletteTests`: green (`Test run with N tests`, N > 0).
- [ ] **Step 5: Look at it.** A throwaway unit test in the mirror only (`ZZAvatarSwatches`, not in the repository) renders the six pairs old (system colours as in `git show HEAD:…AvatarView.swift`) and new at size 48 with the initial, in light and dark, with `ImageRenderer` into one PNG in `$SCR/a11y/`; view it. Also view `before/light/publicProfile-std.png` against a new run of `testPublicProfile_std`.

### Task 5: "Share location" in the label colour

**Files:**
- Modify: `Presentation/Map/MapView.swift` (`sharingButton`)

**Interfaces:** none.

- [ ] **Step 1: Change** the label's `.foregroundStyle(.primary)` on `(isSharing ? Text("Sharing location") : Text("Share location"))` to `.foregroundStyle(Color.primary)` (hierarchical `.primary` inside a `Button` follows the tint and renders blue). Nothing else in `MapView`: the locate button keeps its modifier.
- [ ] **Step 2: Verify** (no permanent test: contrast is not in the guard, by the spec): `ZZAccessibilityAuditThrowaway/testMap_std` in dark and in light (`xcrun simctl ui 902C645A-22D9-47F3-86B0-3E4623B6B2A9 appearance light`, put back to `dark` afterwards) writes `map-std.png` and an `audit.log` with no `contrast` line for "Share location" (the before logs have one in both modes). Look at the PNG against `before/light/map-std.png` and `before/dark/map-std.png`: the label is black in light mode and white in dark.

### Task 6: A solid comments sheet and darker timestamps

**Files:**
- Modify: `Presentation/Feed/VideoFeedView.swift` (the `.sheet(item: $commentsRoute…)` content), `Presentation/Comments/CommentRow.swift` (`time`)

**Interfaces:** none.

- [ ] **Step 1: Change.** After `.presentationDragIndicator(.visible)` add `.presentationBackground(Color(uiColor: .systemBackground))`. In `CommentRow.time` replace `.foregroundStyle(.secondary)` with `.foregroundStyle(Color.primary.opacity(0.6))` (5.7:1 on the light sheet, about 6.8:1 on the dark one; the system's `.secondary` is only 3.4:1 on white). Leave the two `.secondary` captions further down in the file.
- [ ] **Step 2: Verify** (no permanent test, as Task 5): `ZZAccessibilityAuditThrowaway/testComments_std` in dark and in light: `audit.log` has no `contrast` failure on the timestamps (the before light log has them); Look at the PNG against `before/light/comments-std.png` and `before/dark/comments-std.png`: the sheet is opaque, the timestamps readable. The composer (`.background(.bar)`) and the keyboard case still look right.

### Task 7: Upload status that never rests on colour

**Files:**
- Modify: `Presentation/Debug/CopyableStatusBanner.swift`, `Presentation/Upload/UploadVideoView.swift`

**Interfaces:** none (`CopyableStatusBanner(message:isSuccess:)` keeps its signature).

No UI-test route reaches the status line (it needs a picked video and an uploader), so there is no permanent test; the proof is a screenshot, and the announcement can only be heard on a phone.

- [ ] **Step 1: Banner.** The message text is `.foregroundStyle(.primary)` always (no green). A leading symbol, `accessibilityHidden(true)`, in an `HStack(alignment: .firstTextBaseline, spacing: 8)` with the text: success `checkmark.circle.fill` in `Color(red: 31 / 255, green: 119 / 255, blue: 53 / 255)`, anything else `exclamationmark.triangle.fill` in `Color(red: 204 / 255, green: 64 / 255, blue: 0)`: at least 3:1 on white and on `#1C1C1E` (check with `contrast.py`; change a value if it does not). The Copy Message and View Log buttons stay as they are.
- [ ] **Step 2: Announcement.** In `UploadVideoView` give `viewModel.statusMessage ?? viewModel.failedUpload?.message` one name (`private var statusLine: String?`), used by the `Section("Status")` and by `.onChange(of: statusLine) { _, line in if let line { AccessibilityNotification.Announcement(line).post() } }`, the pattern `CommentsView` uses for a failed post. A repeated failure re-announces because the view model clears the line when a new attempt starts.
- [ ] **Step 3: Verify.** Build. A throwaway unit test in the mirror only renders `CopyableStatusBanner` for success and failure, in light and dark, at the default size and `.accessibility3`, through a `UIHostingController` in a window and `drawHierarchy` into PNGs in `$SCR/a11y/`; view them.

### Task 8: The guard

**Files:**
- Modify: `MaraudersUITests/MaraudersAccessibilityUITests.swift`, `MaraudersUITests/MaraudersThaiUITests.swift`

**Interfaces:**
- Consumes: Task 1's `launch(_:textSize:)`. Produces: nothing for later tasks.

- [ ] **Step 1: Audit tests.** Port the navigation helpers `toFeed`, `toComments`, `toTab(_:_:root:)`, `toSettings`, `toSignInSheet` from `.superpowers/accessibility-audit/harness/ZZAccessibilityAuditThrowaway.swift` (proven in 27 runs). Add `private func audit(_ app: XCUIApplication)` = `try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait, .hitRegion]) { issue in issue.element?.label == "Legal" }` (the closure returns true only for Apple Maps' own link, which the audit reports as too small: any other report fails the test). Eight tests, one screen each so a failure names it: `testTheFeedPassesTheStableAudits`, `testTheFeedWithALongCaptionPassesTheStableAudits` (`UITEST_LONG_CAPTION`: the "more" button's hit area), `testCommentsPassTheStableAudits`, `testTheMapPassesTheStableAudits`, `testUploadPassesTheStableAudits`, `testProfilePassesTheStableAudits`, `testSettingsPassesTheStableAudits`, `testTheSignInSheetPassesTheStableAudits` (`UITEST_GUEST`). A comment at the top of the class says why contrast, dynamicType and textClipped are not audited.
- [ ] **Step 2: Prove the guard can fail.** In the **mirror only**, delete `.accessibilityLabel("Open \(handle) profile")` from the avatar button in `FeedClipActionRail.swift` and run `testTheFeedPassesTheStableAudits`: expected red with a `sufficientElementDescription` issue. Run `mirror.sh` again to put the file back. If the audit stays green, the guard is blind to that mutation: say so in the report and use another one (a button that has only an image).
- [ ] **Step 3: Run** the eight audit tests on the real tree: green.
- [ ] **Step 4: Thai test** in `MaraudersThaiUITests.swift`: `testTheCaptionKeepsClearOfTheRailInThaiAtTheLargestTextSize` with `launchInThai(extraArguments: ["UITEST_LONG_CAPTION", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])`: `feed.caption.frame.maxX` is left of the smallest `minX` of `feed.like`, `feed.comments`, `feed.avatar`; `feed.captionToggle.label.hasThaiCharacter`; after a tap the label still has a Thai character and differs from the first. Run it: green.

### Task 9: Docs, the whole pass, the owner's evidence

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Docs.** In `ARCHITECTURE.md`: the `VideoFeedView` row of the component table (about line 141) and the "Layout note" (about line 271): the caption and the rail are two children of one bottom row, the caption clamped with "more" / "less"; a short **Accessibility** subsection after "Localization" (the rules above and the guard: what the audit test covers, what is left out and why, what only a phone can show: VoiceOver paging, Magic Tap, announcements, the Large Content Viewer; and the three open decisions: accent colour, brand red, the heart's colour-only state); the UI flag table (`UITEST_LONG_CAPTION`, `UITEST_NO_CAPTION`); the identifier list (`feed.caption`, `feed.captionToggle`); the unit test line (new count from the Count commands, and `FeedCaptionClampTests`, `AvatarPaletteTests`); the UI test line (the new suite: caption layout, audit guard, the Thai caption test).
- [ ] **Step 2: Scans.** `python3 Marauders-ios/Scripts/find-plain-strings.py` reports nothing new; `git status --short` shows the paths of this plan, and the owner's `RetryingHTTPClient.swift` and two untracked docs exactly as they were.
- [ ] **Step 3: The unit target** (`run.sh unit MaraudersTests`): all green, count equal to 1326 plus the new tests.
- [ ] **Step 4: The UI target** in the background (`run.sh ui MaraudersUITests`, 16 to 34 minutes): the baseline is all green except `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn` (a system Translate sheet on the simulator). Re-run any other red alone before reading it as real.
- [ ] **Step 5: The throwaway audit again** on the final code (`ZZAccessibilityAuditThrowaway`: dark `_std` and `_ax5` of every screen, light `_std`) and compare `audit.log` with `before/logs/`: no `contrast` failure left on Share location, the avatar initials or the comment timestamps; the remaining reports are the system's own (Sign Out in the toolbar, grey secondary text, blue on white, Apple Maps).
- [ ] **Step 6: Evidence for the owner.** Copy the after screenshots to `.superpowers/accessibility-audit/after/` and send each before / after pair with `SendUserFile`: the feed with a long caption (default, accessibility 2, largest, opened; English and Thai), a short and a missing caption, the clip player's audio button at the largest size, the map capsule (light and dark), the comments sheet (light and dark), the avatars old and new, the upload status. State the **Visible** changes, the correction to the spec (the timestamps' grey) and the calls this plan made beyond it (the second fixture flag `UITEST_NO_CAPTION` and the long caption on the streaming fixture, the 12 pt gap between caption and rail, the two status symbol colours, the extra audit of the feed with a long caption). Stop there: commit and push wait for the owner's order.
