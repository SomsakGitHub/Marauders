# ADR-004: Single Xcode app target (no SPM module split)

**Status:** Accepted  
**Date:** 2026-10-09  
**Scope:** `Marauders-ios` packaging and layer enforcement

## Context

After [ADR-003](003-mvvm-clean-architecture.md), the iOS app follows **Clean Architecture** and **MVVM** using **folders** (`Domain/`, `Data/`, `Presentation/`, `Composition/`). A common follow-up is to extract **Swift Package Manager (SPM)** modules so dependencies compile in one direction only:

```text
MaraudersApp  →  MaraudersPresentation  →  MaraudersDomain
                      ↓
               MaraudersData  →  MaraudersDomain
```

For Marauders today:

- One feature surface (feed + upload + debug log).
- ~25–40 Swift sources in the app target; tests already mock `FeedRepository` without a separate Domain package.
- Playback is tightly coupled to **AVFoundation + UIKit** inside `Presentation/Feed/Playback/` — not a reusable framework yet.
- Portfolio goal is to **explain and demonstrate** boundaries, not to ship a multi-app platform SDK.

We need a deliberate choice: split modules now, or stay single-target with documented rules until size or reuse forces a split.

## Decision

Keep **one application target** (`Marauders`) plus test targets (`MaraudersTests`, `MaraudersUITests`). **Do not** add `MaraudersDomain`, `MaraudersData`, or `MaraudersPresentation` SPM products yet.

Layer boundaries are enforced by:

| Mechanism | What it does |
|-----------|----------------|
| **Folder layout** | `Domain/` has no SwiftUI, AVFoundation, or PhotosUI |
| **Protocols in Domain** | `FeedRepository`, `VideoUploadRepository`, `VideoExporting` |
| **Composition root** | `AppDependencyContainer` is the only place that wires `Default*` repositories to use cases and ViewModels |
| **Use cases** | Presentation calls `FetchFeedUseCase` / `UploadFeedVideoUseCase`, not `FeedAPIClient` |
| **Tests** | `MockFeedRepository` in unit tests proves Domain-facing seams |

Xcode uses a **synchronized root group** on `Marauders/` — new files under the correct folder are picked up automatically without manual `project.pbxproj` file entries.

## Alternatives considered

| Option | Pros | Cons | Outcome |
|--------|------|------|---------|
| **Single target + folders** (chosen) | Fast iteration; one scheme; ADR-003 map matches disk; easy for reviewers | Boundaries are **convention**, not compiler-enforced | **Accepted** |
| **SPM: Domain + Data + App** | Compile-time dependency rule; reusable Domain in theory | Xcode workspace churn; `internal`/`public` API noise; playback still stays in app; overhead for portfolio size | **Deferred** |
| **SPM: one `MaraudersKit` framework** | Slightly cleaner than monolith | Blurs layers inside one module; same enforcement problem as folders | **Rejected** |
| **Tuist / codegen for modules** | Scales for large teams | Extra tooling for a small app | **Rejected** |

## When to revisit (triggers to split SPM)

Re-open this ADR if **any** of the following become true:

1. **Second app target** (e.g. admin app, widget extension) needs the same Domain/Data.
2. **Domain grows** beyond feed/upload (auth, profiles, moderation) with multiple teams touching it.
3. **CI policy**: we add a failing check for forbidden imports (e.g. `SwiftUI` in `Domain/`) and still see repeated violations without compile errors.
4. **Extracted playback SDK** — if `FeedPlayerEngine` is reused outside Marauders.

Suggested first split order if triggered:

1. `MaraudersDomain` (entities, protocols, use cases) — zero Apple UI frameworks.
2. `MaraudersData` (API clients, repository implementations, export).
3. Keep **Presentation + Playback + Composition** in the app target until a second consumer exists.

## Consequences

**Positive**

- Lower maintenance for a portfolio-sized codebase; interview story stays “Clean Architecture **in one repo**” without SPM ceremony.
- Refactors (e.g. [ADR-002](002-ios-concurrency.md) actor extraction) touch one target and one test bundle.
- Reviewers can navigate `Domain/` → `Data/` → `Presentation/` without package dependency graphs.

**Negative**

- A developer *can* `import` Data from a ViewModel and the compiler will allow it — discipline and review (or future CI grep) required.
- `public` access control is not exercised; APIs between layers are `internal` to the app module.

**Neutral**

- Moving to SPM later does not invalidate ADR-003 folder names; packages can mirror the same directory names.

## References

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — MVVM + module map
- [ADR-003](003-mvvm-clean-architecture.md) — folder-based layers
- `Marauders-ios/Marauders/Composition/AppDependencyContainer.swift` — composition root
