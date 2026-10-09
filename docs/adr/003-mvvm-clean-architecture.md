# ADR-003: MVVM + Clean Architecture (iOS)

## Status

Accepted

## Context

The app started with `FeedStore` and views calling API clients directly. For a Senior iOS portfolio we need clear **layer boundaries**, testable use cases, and SwiftUI **MVVM** without splitting into multiple SPM modules yet.

## Decision

Single app target, folder-based layers:

```text
Marauders/
  App/                 @main
  Composition/         AppDependencyContainer (wiring)
  Domain/              Entities, repository protocols, use cases
  Data/                API clients, repository implementations, export
  Presentation/        SwiftUI Views + ViewModels (+ Playback UIKit)
```

| Layer | Depends on | Examples |
|-------|------------|----------|
| **Presentation** | Domain (+ playback infra in `Presentation/Feed/Playback`) | `VideoFeedView`, `VideoFeedViewModel` |
| **Domain** | Foundation only | `FetchFeedUseCase`, `FeedRepository` |
| **Data** | Domain | `DefaultFeedRepository`, `FeedAPIClient` |
| **Composition** | All | Injects repositories into use cases and ViewModels |

**MVVM:** Views observe `@Observable` ViewModels; ViewModels call use cases only (no `URLSession` in presentation).

**Playback exception:** `FeedPlayerEngine` and UIKit paging remain presentation infrastructure (AVFoundation), not domain — they are not business rules.

## Consequences

- **Pros:** Mock `FeedRepository` in tests; README/ARCHITECTURE map matches interview narrative; upload and feed share the same pattern.
- **Cons:** More files; not multi-module (acceptable for app size).

## References

- [ARCHITECTURE.md](../../ARCHITECTURE.md)
- [ADR-002](002-ios-concurrency.md)
- [ADR-004](004-single-app-target.md) — why layers are folders, not SPM modules yet
