# Accessibility pass: design

Date: 2026-11-18. Status: **approved by the owner on 2026-11-18 ("อนุมัติ"), including the eight calls at the end; nothing is built yet.**
Size: a small set of changes (about ten Presentation files, one fixture, two test files, ARCHITECTURE.md; no backend, no new dependency), so this is the short design.

## Intent and why

The owner asked whether anything should be done about accessibility. A read-only audit measured it: Apple's `performAccessibilityAudit` on 10 screens, at the default and the largest text size, dark and light (27 runs, from throwaway UI tests in a scratch copy of the app; none of that is in the repository). The base is sound: no control without a name or a trait, every literal label translated into Thai, the heart burst honours Reduce Motion, a failed comment is announced. The defects are a short list, led by one that is not specific to accessibility: a long caption (the backend allows 500 characters) runs under the feed's action rail for every viewer, at the default text size too.

On 2026-11-18 the owner chose approach A: fix what the simulator can prove, and add a guard so it stays fixed.

## Goals

- The feed's caption never runs under the rail, at any text size, in English and in Thai.
- Text we draw reaches 4.5:1 wherever the audit reported a failure in our own views: avatar initials, the map's "Share location", comment timestamps.
- Nothing is cut off or covered at the largest text size in the feed, the clip player and the upload status.
- An upload's result or failure reaches VoiceOver on its own, and success versus failure never rests on colour alone.
- A guard: UI tests fail if a control on the main screens loses its name, role or hit area, or if the caption meets the rail again; a unit test fails if an avatar colour stops passing.

## Non-goals (each stays a separate decision)

- **VoiceOver paging and Magic Tap in the feed.** Whether a VoiceOver user can reach the next clip is not known and only the phone can show it (approach B, a 10-minute hand test). If it fails it gets its own design.
- **Captions for a clip's own audio** (approach C): a feature, tied to the dubbing work.
- **The accent colour.** The app uses the system blue (the `AccentColor` asset is empty): 4.02:1 on white, which can never reach 4.5:1. Several of the 28 "nearly passed" reports in light mode (blue text and blue buttons on white) and the navigation bar's Sign Out, which the audit fails, come from it; the rest of the 28 are the system's own grey secondary text. One value in `AccentColor` would fix the blue ones; the choice (blue or TikTok red) is the owner's and is not made here.
- **The brand red under white text** (Follow button, 3.68:1, "nearly passed" only) and **the like heart telling liked from not liked by colour alone** (white versus `likeRed`, both filled, as on TikTok). Noticed, not changed: both are brand decisions.
- System-drawn controls: the toolbar's Sign Out, placeholders, a disabled button, Apple Maps' own "Legal" link.
- The App Store Accessibility Nutrition Labels (the owner's answers in App Store Connect).

## Anti-goals

A caption that fits keeps today's type and place. Paging, tap to play and double tap to like do not change. Existing accessibility identifiers keep their names (only additions). No look change beyond the ones marked **Visible** below. Nothing is committed or pushed without an explicit order.

## Constraints

- Every target is iOS 27.0. SwiftUI with one UIKit pager (`VerticalFeedPagingView`), which this pass does not touch.
- New texts are localizable and translated into Thai in the same change (recipe in ARCHITECTURE.md; `LocalizationCatalogTests` and `StringCatalogLayoutTests` guard the catalogs).
- Presentation only, plus one UI-test fixture flag in `UITestFeedRepository`: the layer checker gets no new exception.
- Tests run on the iOS 27.2 simulator. The UI suite takes 16 to 34 minutes, and the work runs from a scratch copy because the owner's own edit of `RetryingHTTPClient.swift` is uncommitted.

## Approaches considered

The program (the owner picked A):
- **A, simulator-provable fixes plus a guard (chosen).** About one session.
- B, a VoiceOver hand test on the phone first: runs alongside A, decides whether the feed needs real VoiceOver work; not a substitute, because A fixes things B cannot see.
- C, captions for the clips' own audio: a feature, later.
- D, nothing: the caption defect is visible to every viewer, so no.

The caption's layout:
1. A fixed right inset on the caption, the rail's width as a constant. Smallest edit, but a guess that breaks when the rail grows with the text size or a language has longer labels.
2. **Caption and rail side by side in one bottom row (chosen).** The rail takes its own width and the caption the rest, so they cannot overlap at any size or language and there is no number to keep honest. A little more change in `VideoFeedView`.

Long captions:
1. Cut at a line limit with no way to read the rest. Simple, but a 500-character caption then cannot be read in the feed at all.
2. **Cut at a line limit with a "more" button (chosen), as TikTok does.** Two new texts and one piece of state.

## Design

1. **Caption and rail as one row** (`FeedClipCaptionOverlay`, `FeedClipActionRail`, `VideoFeedView.feedScroll`).
   - The caption and the rail sit in one bottom-aligned row: the rail at its natural width (it drops its own full-screen frame), the caption in the rest. The gradient behind the caption becomes its own full-width layer so it does not shrink with the caption.
   - Collapsed, the caption shows at most 3 lines (2 at accessibility text sizes). When the text is cut, a small "more" button sits under it. It opens the whole caption in a block at most about 40% of the screen high that scrolls inside; "less" closes it. A new clip always starts closed.
   - While the caption fits, it still ignores touches, so tap to play and double tap to like work over it as today. Only the "more" / "less" button takes touches.
   - A soft shadow like the one the heart already has. VoiceOver reads the whole caption whether or not it is cut, and the button keeps its visible word as its label (Voice Control says what it sees).
   - New: the texts "more" and "less" (Thai "ดูเพิ่ม", "ย่อ", for the owner's Thai review like the rest) and the identifiers `feed.caption` and `feed.captionToggle`.
   - **Visible:** a caption longer than 3 lines is shortened with "more"; every caption is a little narrower, because it no longer runs under the rail.

2. **Rail** (`FeedClipActionRail`). Text stops growing at the largest non-accessibility size (`xxxLarge`), and each button shows the Large Content Viewer (as the system tab bar does) to someone who holds it down at accessibility sizes. The count and label texts get the same soft shadow as the icons. A cap rather than growth because the rail is icons with short labels, and its growth is what pushed it over the clip. **Visible:** at accessibility sizes the rail stays small; the white labels have a shadow.

3. **Playback failure card** (`VideoFeedView.playbackOverlay`). Drawn under the caption row and the rail instead of over them, so Like and Comments stay reachable when the card is tall.

4. **Clip player** (`ClipPlayerView.bottomBar`). The audio button's label wraps onto more lines instead of being cut at the largest sizes ("Original audio · Choose a…").

5. **Avatar placeholder** (`AvatarView`). Every gradient stop is mixed with black by a fixed share so the white initial reaches 4.5:1 in light and dark, on avatars of every size. Computed from the system colours: about 40% shade of the light-appearance colours, kept as fixed colours in both appearances, worst stop then 5.5:1. One pair, yellow to orange, cannot get there without turning brown, so it is replaced by purple to pink; the palettes stay six, so nobody's avatar changes pair except the ones that were yellow to orange. **Visible:** placeholder avatars are deeper in tone.

6. **Map "Share location"** (`MapView.sharingButton`). The label asks for `.primary`, but a Button turns the hierarchical `.primary` into the accent blue, so the label is blue today (blue text on a translucent pill, which the audit fails in both modes) while the icon beside it is already `Color.primary`. The label becomes `Color.primary` as well. The locate button's arrow has the same cause, was not flagged, and stays as it is. **Visible:** the label turns black (white in dark mode) instead of blue.

7. **Comments sheet** (the sheet in `VideoFeedView`, `CommentRow`). Two changes. A solid background (`presentationBackground`) for the half-height sheet: today it is see-through glass, mid-grey in light mode over a dark clip, so the grey timestamps fail (whether any grey text passes depends on the frame behind). And the timestamp's grey becomes `Color.primary` at 60% opacity: the system's `.secondary` is only 3.4:1 on white even on a solid sheet (the audit's "nearly passed" class), so the solid sheet alone would move the timestamps from failed to nearly passed, not to 4.5:1; 60% primary is 5.5:1 or better on the sheet in light mode and about 6.8:1 in dark. **Visible:** the sheet is no longer translucent and the timestamps are a little darker. If the owner prefers the glass, the timestamps stay a known light-mode failure. *Amended on 2026-11-18, after the approval, while writing the plan: the first draft said the solid sheet alone fixes every grey text on it; the arithmetic shows it does not.*

8. **Upload status** (`CopyableStatusBanner`, `UploadVideoView`). Success is normal-coloured text with a leading green check, failure the same with a warning triangle (green text on white is 2.2:1, and colour was the only difference). When the status line appears or changes it is announced to VoiceOver, the pattern `CommentsView` already uses for a failed post. **Visible:** an icon beside the status line; the text is no longer green.

9. **Guard** (new `MaraudersAccessibilityUITests.swift`, `UITestFeedRepository`, one unit test, one test in the Thai suite).
   - Fixture flag `UITEST_LONG_CAPTION` gives the feed's fake clip a long caption (no network needed).
   - UI: with it, at the default size and at the largest, the caption's right edge stays left of the rail's left edge; "more" appears, opens the whole caption, "less" closes it. The Thai suite checks the same at the largest size in Thai.
   - UI: Apple's audit limited to the three kinds that are stable (`sufficientElementDescription`, `trait`, `hitRegion`) on the feed, comments, map, upload, profile, settings and the sign-in sheet. Any report fails, except Apple Maps' own "Legal" link.
   - Unit: every avatar gradient stop against white, light and dark, at least 4.5:1.
   - Left out on purpose: the contrast, dynamicType and textClipped audits (39 of the 120 reports were false positives, and system-drawn controls fail in them).

10. **Docs.** ARCHITECTURE.md: the feed's caption row and rail, a short accessibility paragraph with these rules and the guard, the new test counts.

## How it is checked

- Before and after screenshots on the simulator at the default size, accessibility 2 and the largest: the feed with a long caption (English and Thai), the clip player's audio button, the map capsule, the comments sheet (light and dark), the avatars, the upload status. They go to the owner before anything is committed, so every visible change can be vetoed at no cost.
- The throwaway audit run again: no "failed" left on our own views.
- The unit suite, the new UI tests alone, then the whole UI suite (expected: the one known red on the simulator, everything else green).
- Not checkable here: VoiceOver itself and the announcements. That is the phone (approach B).

## Left to the builder

How to know a caption was cut (measure a full-height copy against the limited one), the exact numbers (the 3 lines, the 40% height, the 40% shade, the gap between caption and rail), what each button shows in the Large Content Viewer, which symbols the status line uses, the Thai wording of "more" and "less".

## Calls I made (for the owner to check)

1. "More" instead of cutting the caption with no way back.
2. The rail's text is capped at `xxxLarge` instead of growing.
3. Darker avatars, and purple to pink replaces yellow to orange.
4. "Share location" in the label colour, not blue.
5. A solid comments sheet, and a darker grey for its timestamps.
6. An icon on the upload status line, and its text no longer green.
7. The guard covers names, roles and hit areas by audit, and colours by a unit test; it does not audit contrast, text clipping or Dynamic Type.
8. The accent colour, the brand red and the heart's colour-only state are left alone.
