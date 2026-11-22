# Architecture Decision Records (ADR)

Short, durable notes on **why** we chose a design—not only what the code does.

| ADR | Title |
|-----|--------|
| [001](001-feed-playback-dual-player.md) | Vertical feed: UIKit paging + dual `AVPlayer` |
| [002](002-ios-concurrency.md) | Swift 6: MainActor UI, `actor` media prep, `Sendable` API |
| [003](003-mvvm-clean-architecture.md) | MVVM + Clean Architecture folder layers |
| [004](004-single-app-target.md) | Single app target (no SPM split yet) |
| [005](005-coordinator-router.md) | Coordinator + Router for tab flows |
| [006](006-feed-get-retry.md) | Retry transient failures on GET feed only |
| [007](007-token-refresh.md) | Rotating refresh tokens and a refresh under every 401 |
| [008](008-background-upload.md) | A background upload session, and an idempotency key for the clip |
| [009](009-session-core-package.md) | The session core as a local Swift package |
| [010](010-environments.md) | Environments: scripts that name their target, one backend for now, staging ready |
| [011](011-account-deletion.md) | Account deletion: Apple first, then the files, then the rows |
| [012](012-force-update.md) | Force update: a minimum build read from Firebase Remote Config |

System overview: [ARCHITECTURE.md](../../ARCHITECTURE.md)
