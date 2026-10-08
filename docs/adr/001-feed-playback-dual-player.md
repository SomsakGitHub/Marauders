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
