# ADR-002: iOS concurrency model (Swift 6)

## Status

Accepted

## Context

Feed playback loads `AVURLAsset` / `AVPlayerItem` over the network while UIKit scroll callbacks and SwiftUI state must stay on the main actor. Swift 6 default **MainActor** isolation makes accidental cross-thread UI access a compile-time issue, but heavy media work must not run on the main actor during preparation.

## Decision

| Layer | Isolation | Responsibility |
|-------|-----------|----------------|
| SwiftUI + `FeedStore` + `FeedPlayerEngine` | `@MainActor` | UI state, `AVPlayer` control, layer visibility |
| `FeedAPIClient` / `VideoUploadAPIClient` | `Sendable` | `URLSession` async I/O; no shared mutable state |
| `FeedMediaPreparationService` | `actor` | Asset cache, prefetch until `readyToPlay`, `beginPlaybackItem` for visible slot |
| `VerticalPagingFeedScrollView` coordinator | UIKit thread → `Task { @MainActor }` | Page settle updates bindings and playback hooks |

### Feed reload

`FeedStore.reload()` uses a **generation counter** so stale responses from overlapping `reload()` calls (pull-to-refresh + tab switch) are ignored.

### Prefetch vs playback

- **Prefetch:** actor waits until `AVPlayerItem` is `readyToPlay`, stored in cache.
- **Visible load (no cache):** actor only checks `isPlayable`, then engine assigns item and uses existing KVO for stall UI.

## Consequences

- **Pros:** Clear boundary for media I/O; interview-friendly diagram; Swift 6–clean tests for actor HTTPS rules.
- **Cons:** One extra type to maintain; `load()` always enters a `Task` (minor vs previous sync cache hit).

## References

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — Swift 6 concurrency table
- [ADR-001](001-feed-playback-dual-player.md) — dual player + UIKit paging
