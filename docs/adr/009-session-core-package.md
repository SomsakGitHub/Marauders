# ADR-009: The session core as a local Swift package

**Status:** Accepted  
**Date:** 2026-11-17  
**Scope:** `Marauders-ios/Packages/MaraudersAuth` (targets `MaraudersAuth` and `MaraudersAuthData`), `Data/Auth/AuthModuleBridge.swift`, `Scripts/check-layers.sh` with `Scripts/layer-modules.txt`

## Context

[ADR-004](004-single-app-target.md) keeps the iOS app in one Xcode target: layers are folders, and `Scripts/check-layers.sh` checks them. When it was written the app had 25 to 40 Swift sources and one feature surface. By November 2026 it has 250 files and about 21,500 lines, with sign-in, profiles, follows, comments, likes, location sharing, dubbing and background upload.

None of ADR-004's four triggers has fired: there is no second target, one developer, no repeated rule breaks, no playback SDK. Speed is not a reason either. Measured on 2026-11-17 (Xcode 27.2, iPhone 17 simulator): a clean build takes 21 s, a rebuild after one edit 7 s, and all unit tests after a Domain change 27 s.

The owner chose to make a first module anyway, and chose the session core: the code that says what a session is, keeps it in the Keychain, renews it, and talks to the Worker's `/v1/auth/*` routes. It was 17 files and 1,024 lines, and it used six names of the rest of the app on 19 lines, which made it the part closest to standing alone.

## Decision

The session core is a local Swift package, `Marauders-ios/Packages/MaraudersAuth`, with one library product made of two targets:

| Target | Holds | Imports |
|--------|-------|---------|
| `MaraudersAuth` | The Domain half: the token rules (`APIAccessTokenFormat`, `APIAccessTokenExpiry`, `APIAccessTokenSubject`, `APIRefreshTokenFormat`, `AuthUserID`), `AuthTokens`, the store protocols, `AuthAPIClientProtocol` with `AuthAPIError`, `TokenRefreshing`, and the sign-in use cases | Foundation |
| `MaraudersAuthData` | The Data half: the three Keychain stores, `InstallationSessionGuard`, `TokenRefresher`, `AuthAPIClient`, `DevAuthAPIClient` | Foundation, Security, `MaraudersAuth` |

Both targets compile with the app target's Swift settings (language mode 6, MainActor by default, approachable concurrency, member import visibility), so the moved code keeps its meaning. The package is linked into the app target only. The unit tests stay in the app's test bundle and reach the package through the app that hosts them, with `@testable import`.

The moved files used six names of the app. Four seams replace them:

| Seam | Replaces | How |
|------|----------|-----|
| `AuthTransport` and the marker `AuthTransportFailure` | `HTTPClient`, `URLSessionHTTPClient`, `HTTPClientError` | The package declares what it needs to send a request. The app wraps its own `HTTPClient` and marks `HTTPClientError` as a transport failure, so the refresher asks again after the errors it asked again after before |
| A `baseURL` closure | `APIConfiguration` | The two clients form the four `/v1/auth/*` addresses themselves, under the origin the app supplies |
| `AuthLog` with one `sink` | `AppLog` | `MaraudersApp` points the sink at `AppLog` first thing at launch. Categories, texts and levels are unchanged |
| `InstallationSessionGuard.bootstrap(isUITesting:)` | `AppRuntimeConfiguration.isUITesting` | The app passes the flag |

The app's side of all four is one file, `Data/Auth/AuthModuleBridge.swift`.

What stays in the app: the sign-in screen, `AuthViewModel`, the country picker and the location gate. `RevokeRefreshTokenOnSignOutUseCase` stays too, in `Domain/UseCases`: it needs `TimeBoundedCall`, which `StopLocationSharingOnSignOutUseCase` and `AuthViewModel` also use.

The layer checker reads `Scripts/layer-modules.txt`, which lists the package's two source folders as more Domain and more Data. A file there is a file of that layer, its types belong to that layer, and an import of one of the two modules is judged like naming a type of its layer. So `Domain/` and `Presentation/` may import `MaraudersAuth`, and only `Data/`, `Composition/` and `App/` may import `MaraudersAuthData`.

## Alternatives considered

| Option | Why not |
|--------|---------|
| A module of the sign-in screen (`Presentation/Auth`, 7 files) | It needs 20 types of the app. A package cannot import the app target |
| A module of everything from the screen to the Keychain (26 files) | It still needs the location manager and the sign-out use cases of upload and location sharing, because `AuthViewModel` is the app's session manager and five Presentation folders read it |
| One target instead of two | Only the checker would stop the Domain half from using the Data half, and a file that imports the module could name a Keychain store. With two targets the compiler holds both rules |
| Moving `TimeBoundedCall` into the package, or copying it | Moved, an unrelated use case would import an auth module for a timer. Copied, there would be two versions of subtle concurrency code |
| Import rules alone in the checker | Three rules the checker applied to the moved files would have stopped applying: Foundation only in Domain, no SwiftUI in Data, and no use case named by a view |
| A logger handed to every object | It changes every place a client or the refresher is built. One sink keeps them as they are, and matches how `AppLog` works |
| Tests moved into the package | The Keychain tests need a host app. Nothing is gained yet by splitting the suite |

## Consequences

**Positive**

- The rest of the app reaches the session code only through its 23 public types. Presentation cannot import the Keychain and network half.
- The package builds alone on the Mac in seconds (`swift build --package-path Marauders-ios/Packages/MaraudersAuth`), which proves it names nothing of the app.
- A second package starts from what this one set up: the project wiring, the settings block of `Package.swift`, a line in `layer-modules.txt`, and tests hosted by the app.

**Negative**

- `public` has to be written on those 23 types and on the members the app uses.
- `AuthTokens` carries three `nonisolated` words. Inside one module the compiler lets another actor read a `let` of a struct and writes a non-isolated initializer; a public type used from another module has to say so.
- `AuthLog.sink` is one piece of module-wide state. A line logged before the app sets it is dropped, which is why `MaraudersApp.init()` sets it first.
- The rule "Domain imports Foundation only" now reads "Foundation and `MaraudersAuth`".

**Neutral**

- No behaviour changed. The Keychain service and account names, the accessibility class and the install marker's place are held by `SessionStorageNamesTests`, written before the move, and the four request addresses by `AuthAPIClientTests`.
- The tests did not move. A test file that names a type of the package imports it.

## References

- [ADR-004](004-single-app-target.md), which this amends, and [ADR-007](007-token-refresh.md) for the refresher
- [ARCHITECTURE.md](../../ARCHITECTURE.md): "MVVM + Clean Architecture", "Dependency rules", "Module map"
- Design: `docs/superpowers/specs/2026-11-17-session-core-module-design.md`
- `Marauders-ios/Packages/MaraudersAuth/Package.swift`, `Marauders-ios/Marauders/Data/Auth/AuthModuleBridge.swift`, `Marauders-ios/Scripts/layer-modules.txt`
