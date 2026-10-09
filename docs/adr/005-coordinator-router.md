# ADR-005: Coordinator + Router (app navigation)

**Status:** Accepted  
**Date:** 2026-10-09  
**Scope:** `Marauders-ios` tab navigation and cross-feature flows

## Context

[ADR-003](003-mvvm-clean-architecture.md) placed navigation in `ContentView`: local `@State` for `TabView` selection and an `onUploaded` closure that called `feedViewModel.reload()` and switched tabs. That mixed **screen layout** with **application flow** and made cross-tab behavior harder to test.

The app has few routes today (feed / upload / debug log) but will likely add empty-state CTAs (“go to upload”) and splash-time loading without growing `ContentView`.

## Decision

1. **`AppRouter`** (`@Observable`, Presentation/Navigation): owns **`MainTab`** selection; exposes `showFeed()`, `showUpload()`. SwiftUI views bind `TabView(selection: $router.selectedTab)`.
2. **`AppCoordinator`**: orchestrates **multi-step / cross-tab** flows:
   - Splash → `loadFeedIfNeeded()` via feed ViewModel
   - Upload success → `reload()` feed + `router.showFeed()`
   - Wires `uploadViewModel.onUploaded` once at construction (in `AppDependencyContainer`).
3. **ViewModels** stay feature-scoped; they do not import each other. Coordinator is the only type that combines upload completion with feed reload + tab change.
4. **Composition root** exposes `router`, `coordinator`, and ViewModels from `AppDependencyContainer`.

```text
ContentView ──binds──► AppRouter.selectedTab
UploadVideoViewModel ──onUploaded──► AppCoordinator ──► Feed VM + Router
```

## Alternatives considered

| Option | Pros | Cons | Outcome |
|--------|------|------|---------|
| Closures in `ContentView` | Minimal code | Untestable flow; `onAppear` wiring | **Replaced** |
| SwiftUI `NavigationPath` only | Native stack | Overkill for tab-only app | **Deferred** |
| Per-feature coordinators | Scales to many flows | Two tabs don’t need hierarchy yet | **Deferred** |
| Router + app coordinator | Clear split state vs flow | One more type | **Chosen** |

## Consequences

- **Pros:** `AppCoordinatorTests` can assert tab + feed state after upload; empty-state buttons can call `router.showUpload()` without touching upload VM.
- **Cons:** Coordinator must stay thin — no business rules (those remain in use cases).

## References

- `Presentation/Navigation/AppRouter.swift`, `AppCoordinator.swift`
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — navigation subsection
