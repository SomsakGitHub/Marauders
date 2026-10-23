# ADR-001: Vertical feed playback (UIKit paging + dual AVPlayer)

**Status:** Accepted  
**Date:** 2026-10-09  
**Scope:** `Marauders-ios` feed video playback

## Context

The app is a TikTok-style **vertical full-screen feed**. Requirements:

- Video should **move with the user’s finger** while paging (not a fixed overlay on black cells).
- Avoid **stutter when releasing** after a swipe (common when calling `replaceCurrentItem` on a single player).
- Stay within reasonable **memory** (portfolio app, not unlimited prefetch).
- Work with **HTTPS** progressive MP4 and **HLS** (`master.m3u8`) from the same `streamURL` field.

Early iterations used one `AVPlayer` per cell or a single player in a SwiftUI `ScrollView` overlay. Those approaches caused teardown races, scroll jank from frequent `@State` updates, or visible hitch on clip change.

## Decision

1. **UIKit `UIScrollView` paging** (`VerticalPagingFeedScrollView`) for the feed scroll surface.
2. **Player view inside scroll content** (`FeedPlayerCompositorView`) so the video layer scrolls 1:1 with content offset.
3. **Two player slots** (`FeedPlayerEngine` → slot A / slot B):
   - **Visible** slot plays the current page after settle.
   - **Hidden** slot **preloads** the next neighbor URL (paused at time zero).
   - On page settle, if the hidden slot already has the target URL ready → **`playImmediately` + swap** visible slot (no reload on the visible player).
4. **Playback only on settle** (`settle(on:prefetchNeighbors:)`), not on every scroll offset tick.
5. **Asset prefetch cache** (`prefetch` / `warmURLs`) still prepares `AVPlayerItem` instances for URLs not yet assigned to a slot.

## Alternatives considered

| Option | Pros | Cons | Outcome |
|--------|------|------|---------|
| `AVPlayer` per cell | Simple mental model | Memory, teardown, `Cannot Open` races | Rejected |
| Single player + SwiftUI overlay | One engine | Video doesn’t follow finger; offset hacks re-render SwiftUI | Rejected |
| Single player + scroll offset overlay | Follows finger | Still hitches on `replaceCurrentItem` at settle | Superseded |
| Dual player + UIKit scroll | Smooth scroll + fast swap | ~2× player memory, more state | **Chosen** |
| `UICollectionView` + cell reuse | Production-scale | Heavier wiring for portfolio scope | Deferred |

## Consequences

**Positive**

- Scroll feels native; video is a subview of scroll content at `y = pageIndex × height`.
- Settle path can avoid visible reload when hidden slot is warm.
- HLS and MP4 share the same client pipeline (`AVURLAsset` / `AVPlayer`).

**Negative / limits**

- Two decoders in memory; not suited to unbounded parallel prefetch.
- Hidden slot only preloads **one** neighbor URL at a time; fast flings through many clips may still buffer.
- SwiftUI chrome (`FeedPlaybackChrome`, buffering overlay) sits above the UIKit scroll representable.

**Follow-ups**

- Optional: empty-state UX when `feed_videos` is empty.
- Optional: metrics (time-to-first-frame after settle).
- Scale: server-side HLS for all clips; adaptive ladder; transcode queue (see [ARCHITECTURE.md](../../ARCHITECTURE.md)).

## References

- Code: `VerticalPagingFeedScrollView.swift`, `FeedPlayerEngine.swift`, `FeedPlayerCompositorView.swift`
- Server media: [deployment/video-pipeline.md](../../deployment/video-pipeline.md)
- Tests: `MaraudersTests/FeedPlayerEngineTests.swift`

## Playback correctness follow-up (2026-10-23)

- Keep the first eligible neighbor in the hidden slot across repeated settle calls;
  do not skip it just because it is already requested.
- Validate asynchronous item preparation against a per-slot request identity, so
  a superseded load cannot overwrite that slot.
- Observe both players and route status updates according to the currently visible
  slot. Playback permission is checked again after asynchronous preparation and
  loop seeks, including when the feed has been paused by navigation or lifecycle.
- Asset prefetch caches items after checking playability. It does not wait for an
  unattached item to become ready, and does not imply buffered media. The hidden
  AVPlayer remains responsible for preparing the next item for playback.
- Preserve an active UIKit drag/deceleration when SwiftUI updates the same page
  count instead of resetting its content offset.

Validation: Swift syntax parsing and `git diff --check` passed. The initial
sandboxed build was blocked by SwiftPM cache permissions and CoreSimulator IPC.
Redirecting module/package caches did not redirect SwiftPM manifest diagnostics.
After approved execution outside the sandbox, Xcode 26.6 successfully built and
ran 23 tests across FeedPlayerEngineTests, FeedMediaPreparationServiceTests, and
VideoFeedViewModelTests on the iPhone 17 Pro / iOS 26.5 simulator (`TEST SUCCEEDED`).
No automatic approval rejection occurred.

These unit tests do not measure playback performance. Device validation should
cover repeated settles, rapid forward/back swipes, pause during loading, looping
after a slot swap, and background/foreground transitions. Compare settle-to-first-
frame time and stalls on both MP4 and HLS under the same network before claiming
a measured performance improvement.

### UI playback check

Added `UITEST_STREAMING_FEED`, using the two existing Apple HLS sample URLs,
plus a UI test issuing fast forward/reverse swipes with screenshot attachments.
The simulator showed actual video frames on both clips, and assertions passed
for the first forward, first reverse, and second forward transition. XCTest
logged a 60-second wait for an animation-completion notification before a reverse
swipe; this is automation wait time, not a measured playback stall. The run was
interrupted when testing switched to a physical device, so the full UI test is
not reported as passing. Screenshots do not establish FPS or first-frame latency.

The connected iPhone 16 Pro Max (iOS 26.7.1) build and code signing completed.
The device rejected app launch with “Developer App Certificate is not trusted”,
so physical-device playback is pending device-side trust approval. No app data
was deliberately deleted. Sandbox escalation requests were approved.

Physical-device follow-up: CoreDevice confirmed Developer Mode enabled and the
main app subsequently launched successfully without another settings change.
Re-running the already-built UI test on the same iPhone 16 Pro Max succeeded:
three forward/reverse rounds (six fast-velocity swipe gestures), seven screenshot
attachments, no assertion failures, and no Play Again button at the final check.
The final forward and reverse screenshots both contain actual HLS video frames.
The test took 83 seconds, including an approximately 60-second XCTest animation
notification wait; this duration is not a media latency measurement. These checks
cover two Apple HLS test clips, not the production feed, MP4, continuous rapid
flings, frame pacing, or instrumented time to first frame. Result bundle:
`/tmp/marauders-feed-device-build/Logs/Test/Test-Marauders-2569.10.23_14-31-03-+0700.xcresult`.
