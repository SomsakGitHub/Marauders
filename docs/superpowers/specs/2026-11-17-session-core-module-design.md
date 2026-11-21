# Session core as a local Swift package: design

Date: 2026-11-17
Status: approved by the owner on 2026-11-17 ("อนุมัติ"). Nothing in this document has been built yet; the implementation plan is `docs/superpowers/plans/2026-11-17-session-core-package.md`.
Topic: Modularization. This is the first module of the iOS app.

## Intent

The iOS app is one Xcode target. Its layers are folders, and `Scripts/check-layers.sh` checks them
([ADR-004](../../adr/004-single-app-target.md)). On 2026-11-17 the owner asked what to do about modularization, then
whether Sign in with Apple should become a module, and chose to extract the session core ("แยกแกน session"): the code
that says what a session is, keeps it in the Keychain, renews it, and talks to the Worker's `/v1/auth/*` routes.

The owner gave no reason beyond wanting the split, so this design claims none. Speed is not it: measured the same day,
a clean build takes 21 s, a rebuild after one edit 7 s, and all unit tests after a Domain change 27 s. What the split
gives is a boundary the compiler checks (the rest of the app reaches the session code only through what is `public`)
and the app's first local package, set up so that a second one costs less.

The work moves code. It changes no behaviour.

## Goals

- The 17 files listed under "What moves" live in a local Swift package at `Marauders-ios/Packages/MaraudersAuth` and
  compile there without any type of the app: `swift build` in that folder succeeds on the Mac.
- The app behaves exactly as before: the same requests, the same Keychain items, the same log lines, the same error
  messages, the same order of saves.
- Every test that passes today still passes and still means the same. Tests gain import lines; none is deleted or
  weakened.
- Every layer rule the checker applies today is still applied, to the moved files too. In particular, Presentation
  still cannot reach a Keychain or network type.
- An unsigned Release archive builds and embeds the same frameworks as today (only Lottie).

## Non-goals

- The sign-in screen, `AuthViewModel`, the country picker and the location gate stay in the app.
- `Shared/`, the rest of `Domain/` and the HTTP client are not extracted.
- No test moves into the package and the package gets no test target.
- `RevokeRefreshTokenOnSignOutUseCase` and `TimeBoundedCall` stay in the app (see "Approaches", decision 2).
- No type is renamed. The Worker, the API contract and what is stored do not change.
- Removing Lottie and rewriting ADR-004's context were proposed earlier and not chosen; they are not part of this.

## Anti-goals (a failure even if everything compiles)

- A viewer signed out by the update. The Keychain service `com.somsak.Marauders.auth`, the accounts `apiAccessToken`,
  `apiRefreshToken` and `appleUserID`, the accessibility class, and the marker file
  `Application Support/Installation/session-initialized` must stay byte for byte what they are.
- Two copies of the module in one process, so that the app and the unit tests each have their own
  `InstallationSessionGuard.isReady`.
- A log line of the module that no longer reaches `AppLog`, or a token in the log.
- A layer rule that was checked before the move and is not checked after it.
- The module importing something of the app, or the app's HTTP stack copied into the module.
- Behaviour that drifts because the package compiles with other Swift settings than the app.

## How it works today

Seventeen files, 1,024 lines, in two layers:

- `Domain/Auth/` (9 files) and `Domain/UseCases/SignInWithAppleUseCase.swift`, 350 lines: the token rules
  (`APIAccessTokenFormat`, `APIAccessTokenExpiry`, `APIAccessTokenSubject`, `APIAccessTokenPayload`,
  `APIRefreshTokenFormat`, `AuthUserID`), the store protocols (`AuthSessionStore`, `APIAccessTokenStore`,
  `APIRefreshTokenStore`), `AuthTokens`, `AuthAPIClientProtocol` with `AuthAPIError`, `DevAuthExchanging`,
  `TokenRefreshing` with `TokenRefreshOutcome`, and the two sign-in use cases with `SignInError`.
- `Data/Auth/` (5 files), `Data/API/AuthAPIClient.swift` and `Data/API/DevAuthAPIClient.swift`, 674 lines: the three
  Keychain stores, `InstallationSessionGuard`, `TokenRefresher`, and the two clients of the Worker's auth routes.

They declare 27 top-level types. Fourteen app files outside them name 21 of those types: `App/MaraudersApp.swift`,
four files in `Composition/`, seven in `Data/` (`APIAuthorization`, `DubbedAudioCacheClient`,
`TokenRefreshingHTTPClient`, `FeedStartupCache`, three `BackgroundClipUploader` files),
`Domain/UseCases/RevokeRefreshTokenOnSignOutUseCase.swift` and `Presentation/Auth/AuthViewModel.swift`. Twenty test
files name them.

The 17 files use six names from outside themselves, on 19 lines:

| Name | Where it is used | What for |
|---|---|---|
| `HTTPClient`, `URLSessionHTTPClient` | `AuthAPIClient`, `DevAuthAPIClient` | send a request, get status and body |
| `HTTPClientError` | `TokenRefresher.isWorthAskingAgain` | tell "the Worker could not be reached" from a verdict |
| `APIConfiguration` | the two clients, four calls | the URLs of `/v1/auth/apple`, `/refresh`, `/signout`, `/dev` |
| `AppLog` | 8 calls in 4 files | the lines the Debug log tab shows |
| `AppRuntimeConfiguration.isUITesting` | `InstallationSessionGuard.bootstrap()` | skip the install check in UI tests |

`HTTPClient.swift` and `APIConfiguration.swift` cannot come along. They name `UploadProgressHandler`,
`MultipartBodyWriter`, `UploadProgressDelegate`, `FollowListKind` and `FeedAPIError`, and through those the feed
entities.

The app target compiles with Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency and member
import visibility. Twenty of the 27 types rely on that default. Seven are marked `nonisolated`: the five token rule
enums whose names start with `APIAccessToken` or `APIRefreshToken`, `TokenRefreshing` and `TokenRefreshOutcome`. Unit
tests run inside the app (`TEST_HOST`) and reach it with `@testable import Marauders`.

## Approaches

Three cuts were measured and shown to the owner, who picked the third.

| Cut | Size | Needs from outside itself |
|---|---|---|
| A. The sign-in screen (`Presentation/Auth`) | 7 files, 784 lines | 20 types in 14 files |
| B. Screen, session rules, Keychain and auth API together | 26 files, 1,915 lines | 12 types |
| C. The session core, no screen | 18 files as first measured | 7 names |

A and B cannot stand alone: a package cannot import the app target, and they need the location manager and the
sign-out use cases of upload and location sharing, because `AuthViewModel` is the app's session manager and five
Presentation folders read it. C is close to a leaf. The owner chose C.

Two decisions inside C, both the author's:

1. **One target or two.** In one target the compiler would let the Domain half use the Data half, and would let any
   file that imports the module name a Keychain store; only the checker would object. With two targets the compiler
   holds both rules: `MaraudersAuth` holds the Domain part, `MaraudersAuthData` the Data part and depends on the first,
   and Presentation imports only the first. Chosen: two targets, one product.
2. **Where the revoke use case lives.** `RevokeRefreshTokenOnSignOutUseCase` needs `TimeBoundedCall`, which
   `StopLocationSharingOnSignOutUseCase` and `AuthViewModel` also use. Moving the helper into an auth module would make
   an unrelated use case import auth for a timer; copying it would leave two versions of subtle concurrency code;
   moving the time limit to the caller would change an API and its tests. Chosen: the use case stays in the app, so the
   cut is 17 files and needs six outside names, and `Domain/` may import `MaraudersAuth`.

## Design

### The package

`Marauders-ios/Packages/MaraudersAuth/Package.swift`, tools version 6.2, language mode 6, platforms iOS 27.0 and
macOS 26.0 (macOS only so that `swift build` works on the Mac). One library product `MaraudersAuth` made of two
targets:

- `MaraudersAuth` (`Sources/MaraudersAuth`): imports Foundation only.
- `MaraudersAuthData` (`Sources/MaraudersAuthData`): depends on `MaraudersAuth`; imports Foundation and Security.

Both targets get the app target's settings, so moved code keeps its meaning: `.defaultIsolation(MainActor.self)` and
the upcoming features `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `MemberImportVisibility`.

The folder sits beside `Marauders/`, not inside it: `Marauders/` is a synchronized group, and a package inside it would
be compiled into the app a second time.

### What moves

Moved with `git mv`, so history follows. Names of files and types do not change.

| To `Sources/MaraudersAuth` (10 files) | To `Sources/MaraudersAuthData` (7 files) |
|---|---|
| the 9 files of `Domain/Auth/` | the 5 files of `Data/Auth/` |
| `Domain/UseCases/SignInWithAppleUseCase.swift` | `Data/API/AuthAPIClient.swift`, `Data/API/DevAuthAPIClient.swift` |

### What becomes public

A type is `public` when an app file outside the module names it today, or when a public signature needs it. That is
23 of the 27: sixteen in `MaraudersAuth` (every type listed above except `APIAccessTokenPayload` and `SignInError`)
and seven in `MaraudersAuthData` (`AuthAPIClient`, `DevAuthAPIClient`, `InstallationSessionGuard`, `TokenRefresher` and
the three Keychain stores). `APIAccessTokenPayload`, `SignInError`, `AuthAPIResponse` and
`KeychainAuthSessionStoreError` stay internal; `SignInError` reaches the screen as a `LocalizedError`, which is how
`AuthViewModel` reads it today. Members become public only where outside code uses them; `AuthTokens` gets a written
public initializer. Tests reach the rest with `@testable import`.

### The four seams

Each replaces one outside name. Together they change about 20 lines of the moved files.

1. **Transport.** `MaraudersAuthData` declares what it needs and the app supplies it:

   ```swift
   public struct AuthTransportResponse: Sendable {
       public let data: Data
       public let statusCode: Int
       public var isSuccess: Bool { (200...299).contains(statusCode) }
   }

   /// A status outside 2xx is an answer, not an error. A request that could not be sent or answered throws.
   public protocol AuthTransport: Sendable {
       func data(_ request: URLRequest) async throws -> AuthTransportResponse
   }

   /// Marks a transport's own errors that mean the Worker could not be reached.
   public protocol AuthTransportFailure: Error {}
   ```

   `TokenRefresher.isWorthAskingAgain` asks `error is URLError || error is any AuthTransportFailure`. The app declares
   `extension HTTPClientError: AuthTransportFailure {}`, so the errors that are retried today are retried tomorrow and
   no error changes its type.
2. **Base URL.** `AuthAPIClient(transport:baseURL:)` and `DevAuthAPIClient(transport:baseURL:)` take
   `baseURL: @escaping @MainActor () throws -> URL`, called once per request as `APIConfiguration.apiBaseURL()` is
   today. The module forms its four URLs itself, the way `APIConfiguration` does (`URL(string: "v1/auth/apple",
   relativeTo: base)`). The four `...AuthURL()` functions leave `APIConfiguration`. If a URL cannot be formed, which
   cannot happen with these constants, the module throws an error whose message is today's "API URL must be https://
   with no path".
3. **Log.** `MaraudersAuthData` gets a small facade, `AuthLog`, with three functions (`info`, `warning`, `error`), each
   taking a category and a message as `AppLog`'s do, and one settable `sink`. The moved files call `AuthLog` where they
   call `AppLog` today (same categories, same texts, same `await` from the actor). The app sets the sink once to
   forward to `AppLog`. With no sink set, nothing is logged.
4. **UI-test flag.** `InstallationSessionGuard.bootstrap(isUITesting:)` takes the flag instead of reading
   `AppRuntimeConfiguration`.

### What changes in the app

- One new file in `Data/Auth/` holds the app's side of the seams: an `AuthTransport` that wraps any `HTTPClient`, the
  `HTTPClientError` conformance, the function that points `AuthLog.sink` at `AppLog`, and two convenience initializers
  that keep today's call sites as they are: `AuthAPIClient(session: URLSession = .shared)` and
  `DevAuthAPIClient(client: any HTTPClient = URLSessionHTTPClient())`. Both pass
  `{ try APIConfiguration.apiBaseURL() }`.
- `App/MaraudersApp.swift`: `init()` sets the log sink first, then calls
  `InstallationSessionGuard.bootstrap(isUITesting: AppRuntimeConfiguration.isUITesting)`. The rest of `init()` keeps
  its order.
- `Data/API/APIConfiguration.swift` loses the four auth URL functions.
- The 14 files named under "How it works today" gain `import MaraudersAuth`, `import MaraudersAuthData` or both.
  `AuthViewModel` and `RevokeRefreshTokenOnSignOutUseCase` need only `MaraudersAuth`. Member import visibility may ask
  for the import in a few more files; the compiler names them.

### Layer rules and the checker

The package's two source folders are more Domain and more Data, and the checker is taught to read them that way:
`Sources/MaraudersAuth` as Domain, `Sources/MaraudersAuthData` as Data. Then nothing it checks today is lost:

- Every rule for a `Domain/` or `Data/` file applies to the moved files: Foundation only in the first folder, no
  SwiftUI in the second.
- A type declared in those folders belongs to that layer. A Presentation file that names a Keychain store, and a
  `*View.swift` that names `SignInWithAppleUseCase`, are findings as they are today.
- An import of one of the two modules is judged like naming a type of its layer. `import MaraudersAuth` is allowed
  wherever a Domain type may be named, which makes the Domain rule "Foundation and `MaraudersAuth`".
  `import MaraudersAuthData` is a finding in `Domain/`, `Presentation/` and `Shared/`.

Each new behaviour gets a case in `Scripts/tests/check-layers-tests.sh` first. The compiler adds what the checker
cannot give: `MaraudersAuth` cannot use `MaraudersAuthData`, and neither can use the app.

The lint build phase gains `"$SRCROOT/Packages"`, so the moved files stay linted by the same `.swift-format`.

### The project file

`project.pbxproj` gains an `XCLocalSwiftPackageReference` (`relativePath = Packages/MaraudersAuth`), an
`XCSwiftPackageProductDependency` for `MaraudersAuth`, and that product in the app target's Frameworks phase and
`packageProductDependencies`. The test targets get nothing: the unit test bundle resolves the module's symbols from the
app that hosts it.

### Tests

The 20 test files gain `@testable import MaraudersAuth` and, where they name a Keychain store, the refresher, the guard
or a client, `@testable import MaraudersAuthData`. Nothing else in them should need to change: the convenience
initializers keep `AuthAPIClient(session:)` and `DevAuthAPIClient(client:)`, the `HTTPClientError` conformance keeps the
refresher's retry cases, and `TokenRefresherTests.noTokenReachesTheAppLog` already waits for the module's line to appear
in `AppLogStore`, so it fails if the sink is not set.

## Verification

Run on the iOS 27.2 simulator, as the owner ordered for all test runs.

1. `swift build` in `Packages/MaraudersAuth` succeeds on the Mac.
2. `git diff -M` against the base shows the 17 files as renames whose changed lines are only access modifiers,
   imports and the four seams. The Keychain service and account strings, the accessibility class and the marker path
   are unchanged (grep).
3. `swift-format lint` reports nothing in the worktree, `Packages/` included. (The main checkout shows one line-length
   warning today, from the owner's uncommitted edit of `RetryingHTTPClient.swift`; it is not this work's.)
4. `sh Scripts/tests/check-layers-tests.sh` passes with the new cases, each seen failing first; `check-layers.sh
   --strict` exits 0 on the tree; and a deliberate break in a scratch copy (a SwiftUI import in each package folder, a
   view that names `SignInWithAppleUseCase`) is reported.
5. The unit target: 1,221 tests in 114 suites pass, the same count as before the move.
6. Two mutation checks, each restored afterwards: without the log sink, `noTokenReachesTheAppLog` fails; without the
   `HTTPClientError` conformance, the refresher's retry cases fail.
7. The UI target: 51 of 52, the one red being the known simulator-only comment-language test.
8. An unsigned Release archive succeeds and embeds only `Lottie.framework`.
9. A session survives the update. A Debug build on the simulator signs the test user in by itself whenever it finds no
   session and has a dev-login secret, so being signed in proves nothing unless the secret is absent. The check: a
   build from the main checkout, which has `backend/.dev.vars`, stores a session. The branch build, made in its
   worktree, which has none, is installed over it without deleting the app and launched without
   `SIMCTL_CHILD_MARAUDERS_DEV_LOGIN_SECRET`. It must start signed in, and its log must show no `POST /v1/auth/dev`.
   The first step signs a test user in on the live Worker, so the check runs only on the owner's yes. The other place
   to see it is the owner's phone, when they ask for that.

## Rollout

App only. No Worker deploy, no migration. The work is done on a branch in its own worktree and committed there;
merging, pushing and a TestFlight build are each the owner's yes. The owner's uncommitted edit of
`RetryingHTTPClient.swift` is not among the files touched.

## Documentation to update

- A new `docs/adr/009-session-core-package.md`, a row in `docs/adr/README.md`, and one line in ADR-004 saying it is
  amended by 009 (its decision for everything else stands).
- `ARCHITECTURE.md`: the packaging paragraph, the layer table, the dependency rules and the Enforcement paragraph, the
  module map, and the places that give a path of a moved file.
- `docs/adr/007-token-refresh.md`: the paths of `TokenRefresher` and the auth client.
- `README.md`: the repository layout.
- The header comment of `Scripts/check-layers.sh`.

## Risks, and what was measured before writing this

Measured on a throwaway copy of HEAD `6dfbcb3` outside the repository:

- **The module would be linked twice in a test run.** It is not. With an empty two-target package wired in as described,
  a unit test that imports both targets with `@testable` sees the same type and the same static state as the app; the
  test bundle links nothing of the package and loads its symbols from the app. The whole unit target passed with it
  (1,222 tests, the 1,221 plus the probe).
- **A Release build would not link the package.** An unsigned Release archive of that copy succeeded in 41 s and
  embedded only Lottie.
- **The moved code would not compile under package settings.** `Domain/` and `Shared/` each compile alone as package
  targets with the settings above. A probe build on macOS that held the session files and the outside declarations
  they use reported no error in the session files (it failed only in the app's networking files, which stay behind).

- **The refresher could not recognise the app's error through a protocol of the module.** It can. An actor in the
  package, asking `error is any Marker` from a `nonisolated static` function, sees an app enum that conforms to the
  marker in an extension, whether or not the marker protocol is written `nonisolated`.

Not measured, for the builder to watch:

- A conformer of a now-public protocol in the test target, whose default isolation differs from the app's. The probe's
  one double compiled; the suite has many.
- Xcode's own view: that the package shows in the navigator and that previews still build. Only the owner can look.

## Left to the builder

- The names of the adapter file and its types, and the exact spelling of `AuthLog`.
- The order of the moves. Suggested: the empty package and project wiring first, then the Domain target, then the Data
  target with its seams, the app building and the unit target passing after each.
- Which members need `public`, guided by the compiler.
- How the checker is told about the two extra folders, and how an exception for a file in the package would be written
  if one were ever needed.
- The object identifiers in `project.pbxproj`.

## Calls the author made (open to correction)

1. The package is named `MaraudersAuth` and lives in `Marauders-ios/Packages/`.
2. Two targets in one product, so that Presentation cannot import the Keychain and network half.
3. The revoke use case stays in the app. The cut is therefore 17 files, not the 18 quoted to the owner, and the rule
   "Domain imports Foundation only" becomes "Foundation and `MaraudersAuth`".
4. The module owns its transport protocol and a marker for "could not be reached"; the app adapts its `HTTPClient`.
5. The module forms its own four URLs from a base URL the app supplies.
6. The log goes through one sink set at launch, not through a logger passed to every object. It keeps every call site
   and matches how `AppLog` already works; the price is one piece of module-wide state.
7. Tests stay in the app's test bundle.
8. The checker reads the package's two folders as more Domain and more Data, so no rule it applies today is lost.
   Import rules alone would have been less work, but three rules would have stopped applying to the moved files.
9. A new ADR-009 amends ADR-004 instead of rewriting it.

## Evidence

Collected 2026-11-17 at HEAD `6dfbcb3`, Xcode 27.2, Swift 6.4.2, iPhone 17 simulator on iOS 27.2.

- App: 250 Swift files, about 21,500 lines. Unit tests: 1,221 in 114 suites, about 5 s of test time.
- Clean build 21 s, no-op build 3 s, rebuild after one view or one Domain type changed 7 s, a Domain change followed by
  all unit tests 27 s.
- `check-layers.sh --strict` exits 0 with 9 registered exceptions; none of them is in the 17 files.
- `AuthAPIClient()` is constructed with its default at four places in `AppDependencyContainer` and
  `DevAuthAPIClient()` at one, always over a plain `URLSessionHTTPClient`; tests construct `AuthAPIClient(session:)`
  twelve times and `TokenRefresher` four times.
