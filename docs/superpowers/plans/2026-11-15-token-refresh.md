# Token Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in viewer stays signed in until they sign out, the Worker really rejects the session, or the session sits idle for 90 days: the Worker issues rotating refresh tokens, and the app refreshes on a 401 and repeats the request once.

**Architecture:** The Worker gets a `refresh_tokens` table (hash, family, used and revoked state), a rotation module whose statements are each one SQL statement, and two routes (`/v1/auth/refresh`, `/v1/auth/signout`). Sign-in answers a refresh token only to clients that ask for one, so installed builds keep their 30-day token. The app gets one process-wide actor (`TokenRefresher`) that runs one refresh at a time, and one `HTTPClient` decorator (`TokenRefreshingHTTPClient`) that turns a 401 into refresh-then-replay-once. A session still ends in one place, `AuthViewModel.handleRejectedAccessToken`.

**Tech Stack:** Cloudflare Worker in TypeScript (Neon serverless driver, `jose`), tests on `node:test` over esbuild bundles with a fake Neon; iOS app in Swift 6 (SwiftUI, Swift Testing, Keychain) with default MainActor isolation.

**Spec:** `docs/superpowers/specs/2026-11-15-token-refresh-design.md`. Read it first. This plan adds only what the spec leaves to the builder; where the plan goes beyond the spec it says so under "Calls this plan makes".

## Global Constraints

- **Refresh token:** 32 bytes from `crypto.getRandomValues`, base64url without padding (exactly 43 characters of `A-Za-z0-9_-`). Only its SHA-256 as lowercase hex is stored or compared. Lifetime 90 days from issue; every rotation starts a new 90 days.
- **Leeway:** a token used less than 60 s ago is rotated again in the same family; a token used longer ago is reuse and revokes the whole family.
- **Access token:** HS256 JWT, `sub` = user id. 1 day when the sign-in body has `supportsRefreshTokens: true`. Otherwise 30 days and today's answer `{ accessToken }`, unchanged.
- **Refresh route answers:** 400 for a wrong shape; 401 for an unknown, revoked, expired or reused token, always the body `{"error":"invalid refresh token"}`; 200 `{ accessToken, refreshToken }`; a database failure is 500, never 401. In the app only 400 and 401 from this route mean "rejected"; 429, 5xx, 404, 405, a transport error and a malformed 200 mean "unavailable".
- **Sign-out route:** `POST /v1/auth/signout { refreshToken }` revokes the family and answers 204 also for an unknown, expired or revoked token; 400 for a malformed body; no Bearer token needed.
- **Rate limit:** both new routes share the `auth` limit with sign-in (30 per 60 s per client IP; the Cloudflare `AUTH_RATE_LIMITER` plus the Neon `auth` rule), POST only.
- **Migration:** `backend/sql/022_refresh_tokens.sql`, idempotent, listed by name in `backend/scripts/migrate.mjs`. That script splits on `;` before it strips `--` comments, so no `;` inside a comment.
- **Keychain:** refresh token in service `com.somsak.Marauders.auth`, account `apiRefreshToken`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `nil` until `InstallationSessionGuard.isReady`; `InstallationSessionGuard.resetIfNeeded` clears it with the other credentials.
- **Refresher:** one refresh at a time, in a task the actor owns; one retry after 1 s on a transport failure or 502/503/504, never on 429; saves the new refresh token first, then the access token; writes nothing when the viewer signed out or signed in again meanwhile; one instance per process.
- **Sign-out bound:** 3 s in total (`StopLocationSharingOnSignOutUseCase.defaultTimeout`) for switching sharing off plus revoking. A failed or skipped revoke never holds the sign-out back.
- **Logs:** no token and no hash of a token in `AppLog`, `console.*` or any error message.
- **No UI change, no new string, no new entry in `Marauders-ios/Scripts/layer-exceptions.txt`.**
- **Xcode:** new Swift files in the synchronized groups need no `project.pbxproj` edit. All targets are iOS 27.0; toolchain Xcode 27.2.
- **Git:** stage named files only, never `git add -A`. `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` carries an unrelated uncommitted edit (an `await` removed from an `AppLog.warning`): leave it out of every commit and do not revert it. Commit, push, the migration and the deploy each need the owner's yes (see "Before Task 1").

## Review Focus

Five inputs the spec implies but a happy-path test would miss, most likely first, each pinned by a test:

1. **Several requests get 401 together** (a cold start sends the feed, the Apple check, the profile and dubbing lookups at once). Expect one refresh call, every request replayed with the same new token, no family revoked. Pinned by Task 10 `manyCallersThatMeetTheSameRejectionMakeOneCall` and Task 11 `fiveRejectedRequestsMakeOneRefreshAndFiveReplays`.
2. **The Worker cannot answer when the refresh runs** (offline, 429, 5xx, a rolled-back Worker answering 405, a malformed 200). Expect the viewer stays signed in, no caller sees a 401, public reads fall back to guest, writes fail with a service error. Pinned by Task 3 `aDatabaseFailureIs500NotAnAuthAnswer`, Task 10 outcome tests, Task 11 `anUnavailableRefreshThrowsAndNeverShowsA401`, Task 12.
3. **The refresh answer is lost** (app suspended, signal gone). Expect the refresher's one quick retry to land inside the 60 s leeway, and a retry after the leeway to end the family as the spec accepts. Pinned by Task 5 (59 s and 61 s on a real engine) and Task 10 `aTransportFailureIsRepeatedOnce`.
4. **The viewer signs out, or signs in as someone else, while a refresh is in flight.** Expect nothing written and the old account's request never replayed under the new account. Pinned by Task 10 `aRefreshThatFinishesAfterSignOutWritesNothing`, `aRefreshThatFinishesAfterANewSignInWritesNothing`, `aStoredTokenOfAnotherAccountIsNeverHandedOut`.
5. **An installed build, or an old session, meets the new Worker.** Expect `{ accessToken }` with a 30-day token for a client that never sends the flag, and an old session with no refresh token still ends on a 401 as today. Pinned by Task 4 `aClientWithoutTheFlagGetsExactlyTodaysAnswer`, Task 8 `anExpiredAccessTokenWithoutARefreshTokenStillEndsTheSession`, Task 10 `noRefreshTokenIsRejected`.

Also pinned, because the spec lists them: a replay rejected again ends the session with the new token (Task 14 `aReplayRejectedAgainEndsTheSessionWithTheNewToken`), and no token in logs (Task 3 `noLogLineCarriesATokenOrItsHash`, Task 10 `noTokenReachesTheAppLog`).

## How to run things

- **Worker tests:** `cd backend && npm run test:auth-refresh`; also `npm run typecheck`. The older suites (`test:dev-auth`, `test:follows`, `test:comments`, `test:likes`, `test:feed`, `test:dubbed-audio`) must stay green.
- **App tests, on the connected iPhone** (project rule; the phone must be unlocked and Do Not Disturb on for UI runs). `$SCRATCH` is a throwaway folder outside the repo, the session scratchpad; the phone's id comes from `xcrun xctrace list devices` and the project memory note `feedback-run-tests-on-physical-iphone`:
  ```bash
  xcodebuild test -project Marauders-ios/Marauders.xcodeproj -scheme Marauders \
    -destination 'id=<iPhone id>' -derivedDataPath "$SCRATCH/DerivedData-work" \
    -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" \
    -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/<Suite>
  ```
  A task's "Run" step uses this with the suites it names. Read the result by grepping the output for ` error: ` and `✘`. A compile error means the step failed, which is the expected state in every "see it fail" step. A long UI run is detached so it survives the tool timeout: `perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh -c "xcodebuild test … > $SCRATCH/ui.log 2>&1; echo exit=\$? >> $SCRATCH/ui.log"`, then wait for `exit=` in the log. macOS has no `timeout` command.
- **Layer checker:** `sh Marauders-ios/Scripts/check-layers.sh` prints one warning per violation that `Scripts/layer-exceptions.txt` does not list; expect no output.
- **Unit test count** for the docs: `grep -r --include='*.swift' -o '@Test' Marauders-ios/MaraudersTests | wc -l` (897 in 74 files before this work).

## File Structure

| Area | Create | Modify |
|------|--------|--------|
| Worker | `backend/sql/022_refresh_tokens.sql`, `src/auth/refreshToken.ts` (token shape, hash, constants), `src/auth/session.ts` (`issueSession`), `src/db/refreshTokens.ts` (issue, rotate, revoke), `src/routes/authRefresh.ts` (`handleRefresh`, `handleSignOut`), `scripts/test-auth-refresh.mjs`, `test/authRefresh.test.ts`, `test/fakes/appleIdentityToken.ts` | `scripts/migrate.mjs`, `src/auth/accessToken.ts`, `src/routes/authApple.ts`, `src/routes/authDev.ts`, `src/validation.ts`, `src/index.ts`, `package.json` |
| App, Domain | `Domain/Auth/AuthTokens.swift`, `APIRefreshTokenStore.swift`, `APIAccessTokenSubject.swift`, `TokenRefreshing.swift` (protocol and outcome), `Domain/UseCases/RevokeRefreshTokenOnSignOutUseCase.swift`, `Domain/UseCases/TimeBoundedCall.swift` | `Domain/Auth/AuthAPIClientProtocol.swift`, `Domain/UseCases/SignInWithAppleUseCase.swift`, `StopLocationSharingOnSignOutUseCase.swift` |
| App, Data | `Data/Auth/KeychainAPIRefreshTokenStore.swift`, `TokenRefresher.swift`, `Data/API/TokenRefreshingHTTPClient.swift`, `URLRequest+Bearer.swift`, `HTTPClient+GuestFallback.swift` | `Data/Auth/InstallationSessionGuard.swift`, `Data/API/AuthAPIClient.swift`, `DevAuthAPIClient.swift`, `APIConfiguration.swift`, `RejectedSessionReportingHTTPClient.swift`, `FeedAPIClient.swift`, `CommentsAPIClient.swift`, `UserProfileAPIClient.swift`, `DubbedAudioCacheClient.swift`, `Data/Services/FeedStartupCache.swift` |
| App, rest | `Composition/APITransportComposition.swift`, `Composition/DebugSessionFault.swift` | `Presentation/Auth/AuthViewModel.swift`, `Composition/AppDependencyContainer.swift`, `Composition/UITestRejectedSession.swift`, `App/MaraudersApp.swift` |
| Tests | `RefreshTokenStoreTests`, `AuthAPIClientTests`, `TokenRefresherTests`, `TokenRefreshingHTTPClientTests`, `GuestFallbackTests`, `APITransportCompositionTests`, `DebugSessionFaultTests`, `RevokeOnSignOutTests`, `Support/ScriptedAuthAPI.swift`, `Support/RecordingTransport.swift`, `Support/ScriptedRefresher.swift`, `Support/MemoryRefreshTokenStore.swift` (all under `MaraudersTests/`) | `InstallationSessionGuardTests`, `AuthViewModelTests`, `SessionExpiryTests`, `SignOutLocationSharingTests`, `SignInWithAppleUseCaseTests`, `FeedStartupCacheTests`, `FeedAPIClientTests`, `CommentsAPIClientTests`, `UserProfileAPIClientTests` |
| Docs | `docs/adr/007-token-refresh.md` | `ARCHITECTURE.md`, `README.md`, `docs/ci-cd.md`, `docs/adr/README.md`, `docs/adr/002-ios-concurrency.md` |

## Calls this plan makes (beyond the spec; the owner may overrule any)

1. A failure while storing the refresh token at sign-in is **500 `sign in failed`**, not the 401 the identity-token check uses (Task 4).
2. The refresher hands out the already-stored access token (the shortcut) only when its `sub` equals the rejected token's `sub`; otherwise `.rejected`. This stops one account's request being replayed under another account that signed in meanwhile (Task 10).
3. Sign-out runs **sharing switch-off first, then the revoke with what is left of the same 3 s**, not both at once. A refresh that the switch-off triggers can then not be killed by a revoke that raced it (Task 9).
4. A sign-in answer without a refresh token **clears a stale refresh token** instead of leaving the previous session's (Task 8).
5. The timeout race inside `StopLocationSharingOnSignOutUseCase` is **extracted into one generic helper** the revoke also uses; behavior unchanged, its tests stay green (Task 9).
6. The decorator gets the `reportRejectedReplay` callback for case (c), and the three public reads share **one guest-fallback helper** instead of three copies (Tasks 11, 12).
7. The startup cache is keyed by `sub`; the old per-token folders stay in `Caches` for the system to purge (Task 13).
8. The transport stacking is built in one small `APITransportComposition` so its order can be tested (Task 14).
9. `DevAuthExchanging.accessToken(...)` is renamed `tokens(...)` because it now returns a pair (Task 7).
10. Old `refresh_tokens` rows are not purged in this change (about one row per device per day); the ADR notes it as a follow-up.

## Before Task 1

- [ ] Ask the owner once, in one message: (a) commit `docs/superpowers/` (the spec and this plan) as one commit; (b) do the work in a worktree on its own branch (`superpowers:using-git-worktrees`), so the unrelated `RetryingHTTPClient.swift` edit stays in `main`'s tree only; (c) may each task's local commit below be made as the task passes. A push, the migration and the deploy are asked separately, each time.

---

## Part 1: Worker

### Task 1: Test harness and token primitives

**Files:**
- Create: `backend/src/auth/refreshToken.ts`, `backend/scripts/test-auth-refresh.mjs`, `backend/test/fakes/appleIdentityToken.ts`, `backend/test/authRefresh.test.ts`
- Modify: `backend/src/auth/accessToken.ts`, `backend/package.json`

**Interfaces:**
- Produces (`src/auth/refreshToken.ts`): `REFRESH_TOKEN_LIFETIME_DAYS = 90`, `ROTATION_LEEWAY_SECONDS = 60`, `generateRefreshToken(): string`, `isWellFormedRefreshToken(value: unknown): value is string`, `hashRefreshToken(token: string): Promise<string>`.
- Produces (`src/auth/accessToken.ts`): `type AccessTokenLifetime = "1d" | "30d"` and `signAccessToken(userId: string, signingSecret: string, lifetime: AccessTokenLifetime = "30d"): Promise<string>`. The default keeps every existing caller as it is; the `ACCESS_TOKEN_TTL` constant goes away.

- [ ] **Step 1: Build the harness.** `scripts/test-auth-refresh.mjs` bundles `test/authRefresh.test.ts` with esbuild into an OS temp dir and runs `node --test`, with three plugins: `@neondatabase/serverless` → `test/fakes/neon.ts` (as `scripts/test-follows.mjs` does), `src/db/users` → `test/fakes/users.ts` (as `scripts/test-dev-auth.mjs` does), `src/auth/appleIdentityToken` → `test/fakes/appleIdentityToken.ts`. The Apple fake exports `verifyAppleIdentityToken(identityToken: string, clientId: string): Promise<string>`; it returns `` `apple:${identityToken}` `` and throws `new Error("invalid")` for a token that starts with `invalid`. Add `"test:auth-refresh": "node scripts/test-auth-refresh.mjs"` after `test:follows`.
- [ ] **Step 2: Write the failing tests** in `test/authRefresh.test.ts` (`describe("primitives")`):
  - `generateRefreshToken` returns a string matching `/^[A-Za-z0-9_-]{43}$/`; 1000 calls give 1000 distinct values.
  - `isWellFormedRefreshToken` is true for a generated token and false for `undefined`, `5`, `""`, 42 characters, 44 characters, 42 `a` plus `+`, plus `=`, plus a space.
  - `hashRefreshToken("abc")` equals `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` and any output matches `/^[a-f0-9]{64}$/`.
  - `signAccessToken` (decode with `jose.decodeJwt`): default lifetime gives `exp - iat === 30 * 86400`, `"1d"` gives `86400`, `sub` is the user id.
- [ ] **Step 3: Run `cd backend && npm run test:auth-refresh`.** Expected: FAIL, module `../src/auth/refreshToken` not found.
- [ ] **Step 4: Implement** the two files. Random bytes from `crypto.getRandomValues(new Uint8Array(32))`, base64url by hand (no padding); hash with `crypto.subtle.digest("SHA-256", ...)` to hex.
- [ ] **Step 5: Run** `npm run test:auth-refresh`, `npm run typecheck`, `npm run test:dev-auth`. Expected: all PASS.
- [ ] **Step 6: Commit** (owner's yes from "Before Task 1"): `git add backend/src/auth/refreshToken.ts backend/src/auth/accessToken.ts backend/scripts/test-auth-refresh.mjs backend/test/fakes/appleIdentityToken.ts backend/test/authRefresh.test.ts backend/package.json` → "Add refresh token primitives and the Worker test harness for them".

### Task 2: The `refresh_tokens` table and its module

**Files:**
- Create: `backend/sql/022_refresh_tokens.sql`, `backend/src/db/refreshTokens.ts`
- Modify: `backend/scripts/migrate.mjs`, `backend/test/authRefresh.test.ts`

**Interfaces:**
- Consumes: Task 1 constants.
- Produces (`src/db/refreshTokens.ts`):
  ```ts
  export type RotationResult = { kind: "rotated"; userId: string } | { kind: "rejected" };
  export async function issueRefreshToken(databaseUrl: string, userId: string, tokenHash: string): Promise<void>;
  export async function rotateRefreshToken(databaseUrl: string, presentedHash: string, successorHash: string): Promise<RotationResult>;
  export async function revokeRefreshFamily(databaseUrl: string, presentedHash: string): Promise<void>;
  ```
  Callers pass hashes only; the module never sees a raw token.

- [ ] **Step 1: Write the failing tests** (`describe("refresh token statements")`, `resetFakeNeon()` in `beforeEach`, `respondWith` to script rows):
  - `issueRefreshToken` runs exactly one statement matching `/INSERT INTO refresh_tokens/` and `/gen_random_uuid\(\)/`, whose values include the user id, the hash and `90`.
  - `rotateRefreshToken` when the first statement returns `[{ user_id: U }]`: resolves `{ kind: "rotated", userId: U }`, exactly one statement, matching `/UPDATE refresh_tokens[\s\S]*used_at IS NULL[\s\S]*INSERT INTO refresh_tokens/`, values include both hashes.
  - First `[]`, second `[{ user_id: U }]`: rotated, exactly two statements, the second matching `/used_at > now\(\) - make_interval/` with `60` among its values.
  - Both `[]`: `{ kind: "rejected" }`, exactly three statements, the third matching `/SET revoked_at = now\(\)/`, with the presented hash and **not** the successor hash among its values.
  - A responder that throws makes `rotateRefreshToken`, `issueRefreshToken` and `revokeRefreshFamily` reject with that error (a database failure is never turned into `rejected`).
  - `revokeRefreshFamily` runs one `UPDATE ... SET revoked_at` with the hash as its only value and resolves even when no row matched.
- [ ] **Step 2: Run** `npm run test:auth-refresh`. Expected: FAIL, module not found.
- [ ] **Step 3: Write the migration** exactly as in the spec ("Data"), with a one-line header comment that has no `;`. Append `"../sql/022_refresh_tokens.sql"` to the list in `scripts/migrate.mjs`.
- [ ] **Step 4: Implement the module** with `neon(databaseUrl)` tagged templates, one statement per function call below. The values are parameters (`${...}`), never string-built SQL; type them (`::uuid`, `::text`, `::int`, `::double precision`) so the driver never has to guess.
  ```sql
  -- issue
  INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
  VALUES ($user::uuid, gen_random_uuid(), $hash, now() + make_interval(days => $days::int))

  -- rotate 1: first use
  WITH spent AS (
    UPDATE refresh_tokens SET used_at = now()
    WHERE token_hash = $presented AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
    RETURNING user_id, family_id
  )
  INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
  SELECT user_id, family_id, $successor::text, now() + make_interval(days => $days::int) FROM spent
  RETURNING user_id

  -- rotate 2: used less than the leeway ago (the first answer was probably lost)
  INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
  SELECT user_id, family_id, $successor::text, now() + make_interval(days => $days::int)
  FROM refresh_tokens
  WHERE token_hash = $presented AND used_at IS NOT NULL
    AND used_at > now() - make_interval(secs => $leeway::double precision)
    AND revoked_at IS NULL AND expires_at > now()
  RETURNING user_id

  -- rotate 3: reuse, so the whole family goes (no row of a token that was never used)
  UPDATE refresh_tokens SET revoked_at = now()
  WHERE revoked_at IS NULL
    AND family_id = (SELECT family_id FROM refresh_tokens WHERE token_hash = $presented AND used_at IS NOT NULL)

  -- revoke family (sign-out)
  UPDATE refresh_tokens SET revoked_at = now()
  WHERE revoked_at IS NULL
    AND family_id IN (SELECT family_id FROM refresh_tokens WHERE token_hash = $presented)
  ```
  `rotateRefreshToken` runs statements 1, 2, 3 in that order and stops at the first that returns a row (statement 3 always ends in `rejected`).
- [ ] **Step 5: Run** `npm run test:auth-refresh`, `npm run typecheck`. Expected: PASS. (The SQL itself is proven on a real engine in Task 5; the fake cannot.)
- [ ] **Step 6: Commit**: `backend/sql/022_refresh_tokens.sql backend/scripts/migrate.mjs backend/src/db/refreshTokens.ts backend/test/authRefresh.test.ts` → "Add the refresh_tokens table and its rotation statements".

### Task 3: The refresh and sign-out routes

**Files:**
- Create: `backend/src/routes/authRefresh.ts`
- Modify: `backend/src/validation.ts`, `backend/src/index.ts`, `backend/test/authRefresh.test.ts`

**Interfaces:**
- Consumes: Task 1 and Task 2 exports.
- Produces: `handleRefresh(request: Request, env: Env): Promise<Response>`, `handleSignOut(request: Request, env: Env): Promise<Response>`, and in `validation.ts` `parseRefreshBody(body: unknown): { refreshToken: string }` (throws `FeedValidationError`; the token must pass `isWellFormedRefreshToken`).

- [ ] **Step 1: Write the failing tests** through `worker.fetch` (as `test/follows.test.ts` does, with `env = { DATABASE_URL, JWT_SIGNING_SECRET }` and a `script()` responder that answers rate-limit statements with `[{ count: 1 }]` and `refresh_tokens` statements as each test scripts). Use a generated token as the presented one.
  - `aWrongShapeIs400`: `{}`, `{ refreshToken: 5 }`, 42 and 44 characters, a `+` in the token, a non-JSON body, `[]`, `null` → 400, no `refresh_tokens` statement ran.
  - `aFirstUseRotatesAndAnswersAPair`: first statement returns `[{ user_id: U }]` → 200, keys `accessToken` and `refreshToken`, `cache-control: private, max-age=0, no-store`; the new refresh token is well-formed and differs from the presented one; `hashRefreshToken(newToken)` is among the values of the rotate statement; the access token verifies with `JWT_SECRET`, `sub === U`, `exp - iat === 86400`.
  - `aSecondUseInsideTheLeewayAnswersAgain`: first statement `[]`, second `[{ user_id: U }]` → 200 with a different new pair; exactly two `refresh_tokens` statements.
  - `anUnknownRevokedExpiredOrReusedTokenIs401WithOneBody`: all statements `[]` → 401, body exactly `{"error":"invalid refresh token"}`, and the third statement (the family revoke) ran with the presented hash.
  - `aDatabaseFailureIs500NotAnAuthAnswer`: the responder throws on `refresh_tokens` → 500 (never 401), and the body does not contain the error text.
  - `noLogLineCarriesATokenOrItsHash`: replace `console.log`, `console.warn`, `console.error`, `console.info` with recorders for the duration of all cases above; no recorded argument contains the presented token, the new token or either hash.
  - `signOutAnswers204ForAKnownAndAnUnknownToken` (the family `UPDATE` ran with the hash both times); `signOutWithAWrongShapeIs400`; `signOutDatabaseFailureIs500`; sign-out needs no `Authorization` header.
  - `bothRoutesShareTheAuthRateLimit`: with the Neon rate counter returning `[{ count: 31 }]` both routes answer 429 with a `retry-after` header and no `refresh_tokens` statement runs; with `env.AUTH_RATE_LIMITER = { limit: async () => ({ success: false }) }` both answer 429 as well. `GET /v1/auth/refresh` is not handled by the refresh route (not 200).
- [ ] **Step 2: Run** `npm run test:auth-refresh`. Expected: FAIL (404/405 for the new paths, module not found).
- [ ] **Step 3: Implement** `parseRefreshBody` and the two handlers in `src/routes/authRefresh.ts`, with the local `jsonResponse`/`jsonError` pair the other auth routes keep (same headers). `handleRefresh`: config checks as in `authApple.ts` (503 `service configuration incomplete` for a missing or short secret or URL), parse (400), generate the successor, `rotateRefreshToken` with the two hashes, then on `rotated` sign a `"1d"` access token for `userId` and answer `{ accessToken, refreshToken: <successor> }`; `rejected` → 401; any thrown error → 500 `refresh failed`. `handleSignOut`: URL check only, parse, `revokeRefreshFamily`, 204 with the no-store headers, any thrown error → 500.
- [ ] **Step 4: Wire `src/index.ts`.** `isAuthRoute` becomes true for `/v1/auth/apple`, `/v1/auth/dev`, `/v1/auth/refresh`, `/v1/auth/signout`; the POST branch (database limit, then handler) covers all four, choosing the handler by path. Nothing else about the router changes.
- [ ] **Step 5: Run** `npm run test:auth-refresh`, `npm run typecheck`, `npm run test:follows`. Expected: PASS.
- [ ] **Step 6: Commit**: `backend/src/routes/authRefresh.ts backend/src/validation.ts backend/src/index.ts backend/test/authRefresh.test.ts` → "Add POST /v1/auth/refresh and /v1/auth/signout".

### Task 4: Sign-in hands out a refresh token to clients that ask

**Files:**
- Create: `backend/src/auth/session.ts`
- Modify: `backend/src/routes/authApple.ts`, `backend/src/routes/authDev.ts`, `backend/src/validation.ts`, `backend/test/authRefresh.test.ts`

**Interfaces:**
- Produces: `issueSession(env: { DATABASE_URL: string; JWT_SIGNING_SECRET: string }, userId: string, supportsRefreshTokens: boolean): Promise<{ accessToken: string; refreshToken?: string }>`; in `validation.ts` `parseSupportsRefreshTokens(value: unknown): boolean` (`undefined`, `null` and `false` give `false`, `true` gives `true`, anything else throws `FeedValidationError("supportsRefreshTokens must be a boolean")`), and `parseAppleAuthBody` also returns `supportsRefreshTokens: boolean`.

- [ ] **Step 1: Write the failing tests** (drive `handleAppleAuth` through the fake verifier and `handleDevAuth` with a valid dev secret; scripted fake Neon for `refresh_tokens`):
  - `aClientWithoutTheFlagGetsExactlyTodaysAnswer` (both routes; flag absent and `false`): JSON keys are exactly `["accessToken"]`, `exp - iat === 30 * 86400`, no `refresh_tokens` statement ran.
  - `aClientWithTheFlagGetsAPair` (both routes): keys sorted `["accessToken","refreshToken"]`, `exp - iat === 86400`, refresh token well-formed; exactly one `INSERT INTO refresh_tokens` with the user id and `hashRefreshToken(refreshToken)` among its values and the raw token not among them.
  - `twoSignInsStartTwoFamilies`: two sign-ins give different refresh tokens, each with its own insert.
  - `aFlagOfTheWrongTypeIs400` (`"true"`, `1`, `{}`, `[]`, both routes): no user upsert, no insert.
  - `aFailureStoringTheRefreshTokenIs500AndGivesNoToken`: the insert throws → 500, the body has no `accessToken` and no `refreshToken` (Apple route: not the 401 the identity-token check gives).
  - `anInvalidAppleTokenIsStill401`: the fake verifier rejects → 401 `invalid apple identity token`.
- [ ] **Step 2: Run** `npm run test:auth-refresh`. Expected: FAIL.
- [ ] **Step 3: Implement.** `issueSession` without the flag signs a 30-day token and touches no database. With it: generate a token, `issueRefreshToken(databaseUrl, userId, await hashRefreshToken(token))` first, then sign the `"1d"` token, so a stored row always exists for a token that was handed out. Both routes parse the flag before any database write. `authApple.ts`: call `issueSession` outside the existing `try` that maps everything to 401 and map its failure to 500 `sign in failed`. `authDev.ts`: its existing catch already answers 500.
- [ ] **Step 4: Run** `npm run test:auth-refresh`, `npm run test:dev-auth`, `npm run typecheck`. Expected: PASS. If `test:dev-auth` now fails to bundle or call the real Neon driver, swap `@neondatabase/serverless` for `test/fakes/neon.ts` in `scripts/test-dev-auth.mjs` the same way `test-follows.mjs` does.
- [ ] **Step 5: Commit**: `backend/src/auth/session.ts backend/src/routes/authApple.ts backend/src/routes/authDev.ts backend/src/validation.ts backend/test/authRefresh.test.ts` (plus `backend/scripts/test-dev-auth.mjs` if touched) → "Hand out a refresh token at sign-in to clients that ask for one".

### Task 5: Check the SQL on a real Postgres engine (PGlite, scratch only)

**Files:** none in the repo. Everything lives in `$SCRATCH/pglite-check/`.

- [ ] **Step 1: Ask the owner** to approve installing `@electric-sql/pglite` into `$SCRATCH/pglite-check/` (a download; the repo's `package.json` is not touched). Do nothing else in this task until they say yes.
- [ ] **Step 2: Write the check script** in the scratch folder. It bundles `backend/src/db/refreshTokens.ts` with esbuild, swapping `@neondatabase/serverless` for a small adapter whose `neon()` returns a tagged template that turns `${...}` into `$1..$n` and runs `db.query(text, values)` on one PGlite instance, returning `rows`. It creates a stub `app_users (id uuid primary key default gen_random_uuid())`, then applies `backend/sql/022_refresh_tokens.sql` with the same `;`-split and `--`-strip as `scripts/migrate.mjs`.
- [ ] **Step 3: Assert on the real engine** (each case on a fresh family; backdate with `UPDATE refresh_tokens SET used_at = now() - interval '...'` where needed):
  1. The migration applies twice without error.
  2. `issueRefreshToken` makes one row, `used_at` and `revoked_at` null, `expires_at` within 1 minute of now + 90 days; a second row with the same hash is refused by the unique index.
  3. First rotate → `rotated` with the user id; the presented row has `used_at`; a successor exists in the same family with `expires_at` ≈ now + 90 days.
  4. Rotate the same token again at once → `rotated` again, a second successor, three rows in the family.
  5. Used 59 s ago → `rotated`; used 61 s ago → `rejected` **and** every row of the family has `revoked_at`; the never-used successor then also gets `rejected`.
  6. Unused but expired (`expires_at` in the past) → `rejected`, the family's other rows keep `revoked_at` null.
  7. A revoked token → `rejected`. An unknown hash → `rejected`, no row changed.
  8. `revokeRefreshFamily` sets `revoked_at` on every row of that family and on no row of another family; an unknown hash changes nothing and does not throw; a second call changes nothing.
  9. `DELETE FROM app_users` removes the user's rows (cascade).
- [ ] **Step 4: Run it.** Expected: every assertion passes. Keep the output; the final report quotes the PGlite version and the case count. PGlite has one connection, so two simultaneous uses cannot be shown here; that case rests on Postgres READ COMMITTED re-checking `used_at IS NULL` after the first `UPDATE` commits (see the spec's "Verification").
- [ ] **Step 5: If any case fails**, the statement in `src/db/refreshTokens.ts` is wrong: fix it there, re-run Task 2's tests, then re-run this check. No commit for the scratch files.

---

## Part 2: App

Run every Swift step with the phone recipe in "How to run things". The suite names below are the Swift Testing struct names.

### Task 6: Refresh token storage

**Files:**
- Create: `Marauders-ios/Marauders/Domain/Auth/APIRefreshTokenStore.swift`, `.../Data/Auth/KeychainAPIRefreshTokenStore.swift`, `Marauders-ios/MaraudersTests/RefreshTokenStoreTests.swift`, `Marauders-ios/MaraudersTests/Support/MemoryRefreshTokenStore.swift`
- Modify: `.../Data/Auth/InstallationSessionGuard.swift`, `.../Composition/UITestRejectedSession.swift`, `Marauders-ios/MaraudersTests/InstallationSessionGuardTests.swift`

**Interfaces:**
- Produces:
  ```swift
  protocol APIRefreshTokenStore: Sendable {           // same isolation as APIAccessTokenStore
      func loadRefreshToken() -> String?
      func saveRefreshToken(_ token: String) throws
      func clearRefreshToken() throws
  }
  enum APIRefreshTokenFormat { static func isValid(_ token: String) -> Bool }   // 32...256 characters, only A-Z a-z 0-9 - _
  struct KeychainAPIRefreshTokenStore: APIRefreshTokenStore {
      init(service: String = "com.somsak.Marauders.auth", account: String = "apiRefreshToken")
  }
  // InstallationSessionGuard.resetIfNeeded(marker:sessionStore:tokenStore:refreshTokenStore:) throws   (a new third store)
  ```
  `MemoryRefreshTokenStore` is a test class (`var token: String?`) implementing the protocol.

- [ ] **Step 1: Write the failing tests.** `RefreshTokenStoreTests`: a Keychain store on a unique service name (`defer` clears it, as `InstallationSessionGuardTests` does): `aSavedRefreshTokenComesBack` (save, load equal, second save replaces, clear gives `nil`, clearing twice does not throw); `aTokenOfTheWrongShapeIsRefused` (`APIRefreshTokenFormat.isValid` is true for 43 base64url characters, false for `""`, 31 and 257 characters, and for a string containing `+`, `=`, a space or a newline; `saveRefreshToken("short")` throws and `loadRefreshToken()` stays `nil`); `theUITestSessionStartsWithoutARefreshToken` (a `UITestRejectedSession` loads `nil`, keeps one it is given, clears it). `InstallationSessionGuardTests`: update both existing calls to pass a refresh store, and assert the refresh token saved before the first reset is gone after it, survives the second run (marker present) and is gone again after the marker is removed; add `aRefreshTokenThatCannotBeClearedDoesNotMarkInstallationComplete` (a failing refresh store → throws, no marker).
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/RefreshTokenStoreTests -only-testing:MaraudersTests/InstallationSessionGuardTests`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement.** The Keychain store mirrors `KeychainAPIAccessTokenStore` line for line (same query, same `InstallationSessionGuard.isReady` rule for the real service name, same error type) with the new account and `APIRefreshTokenFormat` for the save check. `resetIfNeeded` clears the refresh token with the other two before it writes the marker; `bootstrap()` passes `KeychainAPIRefreshTokenStore()`. `UITestRejectedSession` conforms with an in-memory value that starts `nil`.
- [ ] **Step 4: Run** the same suites, then `MaraudersTests/SessionExpiryTests`. Expected: PASS.
- [ ] **Step 5: Commit**: the files above → "Store a refresh token in the Keychain and clear it with the other credentials".

### Task 7: Sign-in and refresh through the auth API client

**Files:**
- Create: `Marauders-ios/Marauders/Domain/Auth/AuthTokens.swift`, `Marauders-ios/MaraudersTests/AuthAPIClientTests.swift`
- Modify: `.../Domain/Auth/AuthAPIClientProtocol.swift`, `.../Data/API/AuthAPIClient.swift`, `.../Data/API/DevAuthAPIClient.swift`, `.../Data/API/APIConfiguration.swift`, `.../Domain/UseCases/SignInWithAppleUseCase.swift` (only enough to compile), and the test doubles in `AuthViewModelTests.swift`, `SessionExpiryTests.swift`, `SignOutLocationSharingTests.swift`, `SignInWithAppleUseCaseTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct AuthTokens: Equatable, Sendable { let accessToken: String; let refreshToken: String? }
  protocol AuthAPIClientProtocol: Sendable {
      func exchangeAppleIdentityToken(_ identityToken: String, countryCode: String) async throws -> AuthTokens
      /// The answer always carries a refresh token; one without a valid one throws `.invalidResponse`.
      func refreshTokens(using refreshToken: String) async throws -> AuthTokens
      func revokeRefreshToken(_ refreshToken: String) async throws
  }
  protocol DevAuthExchanging: Sendable {
      func tokens(secret: String, label: String, countryCode: String) async throws -> AuthTokens
  }
  // AuthAPIError gains: case refreshRejected      // 400 or 401 from /v1/auth/refresh
  // APIConfiguration gains: static func refreshAuthURL() throws -> URL; static func signOutAuthURL() throws -> URL
  ```

- [ ] **Step 1: Write the failing tests** (`AuthAPIClientTests`, `AuthAPIClient(session: StubURLSessionFactory.make { ... })`; the dev client under `#if DEBUG` over a stubbed `HTTPClient`):
  - `signInSendsTheOptInFlagAndReadsThePair`: POST `/v1/auth/apple`, JSON body has `identityToken`, `country` upper-cased and `supportsRefreshTokens == true`; answer `{accessToken, refreshToken}` → `AuthTokens` with both.
  - `anAnswerWithoutARefreshTokenGivesNil`: `{accessToken}` → `refreshToken == nil`, no throw. A refresh token of the wrong shape in a sign-in answer → `.invalidResponse`.
  - `refreshPostsTheTokenWithoutAnAuthorizationHeader`: POST `/v1/auth/refresh`, body exactly `{"refreshToken":"…"}`, no `Authorization` header, answer pair returned.
  - `refreshAnswering400Or401IsRefreshRejected` (arguments 400, 401); `refreshAnswering429500502503404405IsServerErrorWithTheStatus` (arguments); a 200 without a valid refresh token, or with undecodable JSON, is `.invalidResponse`.
  - `revokePostsToThatRouteAndAcceptsAny2xx`: POST `/v1/auth/signout` with the body, 204 returns; 500 throws `.serverError(500)`.
  - `theDevClientSendsTheFlagToo` (`#if DEBUG`).
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/AuthAPIClientTests`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement.** Replace the `[String: String]` request body with an `Encodable` struct so the Bool encodes as a Bool. Extend `AuthAPIResponse` with `let refreshToken: String?`. The refresh and revoke calls log `POST /v1/auth/refresh` / `POST /v1/auth/signout` under `api.auth` and nothing else. Request timeouts: 30 s refresh, 10 s revoke. `AuthAPIError.refreshRejected` gets a user-facing `errorDescription` ("Your session has ended. Please sign in again.") and `httpStatusCode` nil. Update every `AuthAPIClientProtocol` and `DevAuthExchanging` conformer in the tests (`StubAuthAPIClient`, `FailingAuthAPIClient`, `RecordingAuthAPIClient`, `UnusedAuthAPI`, `NoAuthAPI`, `WorkerSpy`, `DevWorkerSpy`) to return `AuthTokens(accessToken:refreshToken: nil)` for sign-in and to throw `AuthAPIError.invalidResponse` from the new methods. `SignInWithAppleUseCase` and `SignInAsDevUserUseCase` save `tokens.accessToken` for now (Task 8 adds the refresh token).
- [ ] **Step 4: Run** `MaraudersTests/AuthAPIClientTests`, `AuthViewModelTests`, `SessionExpiryTests`, `SignOutLocationSharingTests`, `SignInWithAppleUseCaseTests`. Expected: PASS.
- [ ] **Step 5: Commit** → "Read a refresh token at sign-in and add the refresh and revoke calls to the auth client".

### Task 8: Sign-in saves the pair; the session logic knows refresh tokens

**Files:**
- Modify: `.../Domain/UseCases/SignInWithAppleUseCase.swift`, `.../Presentation/Auth/AuthViewModel.swift`, `.../Composition/AppDependencyContainer.swift` (only the `AuthViewModel(` call, to compile), the tests that construct `AuthViewModel` (`AuthViewModelTests`, `SessionExpiryTests`, `SignOutLocationSharingTests`), `SignInWithAppleUseCaseTests`

**Interfaces:**
- Consumes: Task 6, Task 7.
- Produces: `SignInWithAppleUseCase.init(authAPI:sessionStore:tokenStore:refreshTokenStore:)` and `SignInAsDevUserUseCase.init(devAuth:sessionStore:tokenStore:refreshTokenStore:)`; `AuthViewModel.init(sessionStore:tokenStore:refreshTokenStore:authAPI:devAuth:credentialState:signsInAsTestUserOnSimulator:)` (`refreshTokenStore: APIRefreshTokenStore`, required, after `tokenStore`).

- [ ] **Step 1: Write the failing tests.**
  - `SignInWithAppleUseCaseTests`: `signingInSavesTheUserThenTheRefreshTokenThenTheAccessToken` (spies append to one shared event list; expect `["user", "refresh", "access"]`); `anAnswerWithoutARefreshTokenClearsAStaleOne` (a refresh token already stored is gone after the sign-in); the same two for the dev use case; a failing save leaves nothing newer than it saved.
  - `SessionExpiryTests` (give `MemorySessionStorage` a `refreshToken` and the refresh conformance): `anExpiredAccessTokenWithARefreshTokenKeepsTheSession` (Apple authorized → `isSignedIn`, neither token cleared, and the auth double saw zero calls: no refresh at launch); `anExpiredAccessTokenWithoutARefreshTokenStillEndsTheSession` (existing behavior, refresh token `nil`); `anExpiredAccessTokenWithAMalformedRefreshTokenEndsTheSession` (`"short"`); `aRefreshWhileAppleIsAnsweringKeepsTheSession` (`whileAnswering` writes new tokens as the refresher would; afterwards `isSignedIn == true` and the new tokens are still stored); keep `aRejectionWhileAppleIsAnsweringIsNotUndone` as it is; **rewrite** `aNewSignInWhileAppleIsAnsweringIsNotUndone` so the new session comes in through `completeSignIn` (an auth double returning a pair), keeping its assertions.
  - `AuthViewModelTests`: `aRejectedTokenClearsTheRefreshTokenToo`; `signingOutClearsBothTokens`; `restoringWithAnUnreadableUserIDClearsTheRefreshToken`.
- [ ] **Step 2: Run** the four suites. Expected: FAIL (does not compile / the new tests fail).
- [ ] **Step 3: Implement.** Use cases: after the single `await`, three synchronous saves in this order with no `await` between them: user id, refresh token (or `clearRefreshToken()` when the answer has none), access token. `AuthViewModel`: add `private let refreshTokenStore`, `private var sessionGeneration = 0` bumped in `clearStoredSession()`, after a successful `completeSignIn` and after a successful `signInAsDevUser` (never by a refresh). `clearStoredSession()` also clears the refresh token. `restoreSession()`: a session is live when the user id and access token are valid and either the access token is not expired or a refresh token passing `APIRefreshTokenFormat.isValid` is stored; capture `sessionGeneration` before `await credentialState(userID)` and return early afterwards only when it moved (replacing the access-token comparison). `handleRejectedAccessToken(_:)` keeps its access-token comparison. Update every `AuthViewModel(` call site (grep for it) to pass a `MemoryRefreshTokenStore` or the storage double.
- [ ] **Step 4: Run** the four suites plus `RejectedSessionReportingTests`. Expected: PASS.
- [ ] **Step 5: Commit** → "Save the refresh token at sign-in and keep a session that has one".

### Task 9: Sign-out revokes the refresh token

**Files:**
- Create: `.../Domain/UseCases/TimeBoundedCall.swift`, `.../Domain/UseCases/RevokeRefreshTokenOnSignOutUseCase.swift`, `Marauders-ios/MaraudersTests/RevokeOnSignOutTests.swift`
- Modify: `.../Domain/UseCases/StopLocationSharingOnSignOutUseCase.swift`, `.../Presentation/Auth/AuthViewModel.swift`

**Interfaces:**
- Produces:
  ```swift
  enum TimeBoundedCall {
      enum Outcome<Value: Sendable>: Sendable { case finished(Value), failed(reason: String), timedOut }
      static func run<Value: Sendable>(timeout: Duration, _ operation: @escaping @Sendable () async throws -> Value) async -> Outcome<Value>
  }
  struct RevokeRefreshTokenOnSignOutUseCase {
      enum Outcome: Equatable, Sendable { case revoked, nothingToRevoke, failed(reason: String), timedOut }
      init(authAPI: any AuthAPIClientProtocol, refreshTokenStore: any APIRefreshTokenStore)
      func execute(within timeout: Duration) async -> Outcome      // reads the stored token when it runs
  }
  // AuthViewModel.init gains: signOutWindow: Duration = StopLocationSharingOnSignOutUseCase.defaultTimeout
  ```

- [ ] **Step 1: Baseline.** Run `MaraudersTests/SignOutLocationSharingTests`; expected PASS (the safety net for the extraction).
- [ ] **Step 2: Write the failing tests** (`RevokeOnSignOutTests`, an auth double that records the token it was asked to revoke and what the store held at that moment):
  - `signingOutRevokesTheStoredRefreshTokenBeforeClearing`: the double saw the token while it was still stored; afterwards both tokens are cleared and `isSignedIn` is false.
  - `signingOutIsNotHeldBackByARevokeThatNeverAnswers`: the revoke suspends forever, `signOutWindow: .milliseconds(300)` → `signOut()` returns within 2 s, tokens cleared.
  - `aFailedRevokeStillSignsOut` (throws) and `signingOutWithoutARefreshTokenCallsNothing`.
  - `theRevokeUsesTheTokenStoredAfterSharingWasSwitchedOff`: the sharing double rewrites the stored refresh token during its call (as a refresh would); the revoke double receives the new one.
  - `aRevokeIsSkippedWhenSharingUsedTheWholeWindow`: sharing takes longer than `signOutWindow` → the revoke double is never called, sign-out still completes.
  - `endedSessionsRevokeNothing`: `handleRejectedAccessToken`, a revoked Apple credential in `restoreSession()` and an expired token with no refresh token call the revoke zero times.
  - `aFailedOrTimedOutRevokeIsLoggedWithoutTheToken`: a `warning` in category `auth` appears (use the `logged(_:_:)` helper pattern of `SignOutLocationSharingTests`) and no `AppLogStore.shared.entries` message contains the token.
- [ ] **Step 3: Run** `RevokeOnSignOutTests`. Expected: FAIL (does not compile).
- [ ] **Step 4: Implement.** Extract the call-versus-timer race of `StopLocationSharingOnSignOutUseCase` (the `Race` class and its continuation) into `TimeBoundedCall.run`, then map `.finished`/`.failed`/`.timedOut` onto its existing `Outcome` cases with unchanged behavior. The revoke use case returns `.nothingToRevoke` without a call when no refresh token is stored. `AuthViewModel.signOut()` for a signed-in viewer: note the clock, `await switchLocationSharingOff()`, then `revokeRefreshToken(within: signOutWindow - elapsed)` which is skipped when nothing is left, then `clearStoredSession()` as today; it logs the revoke outcome in category `auth` (a warning for failed or timed out, no token in the text).
- [ ] **Step 5: Run** `RevokeOnSignOutTests`, `SignOutLocationSharingTests`, `AuthViewModelTests`, `SessionExpiryTests`. Expected: PASS.
- [ ] **Step 6: Commit** → "Revoke the refresh token on sign-out within the same 3 second window".

### Task 10: `TokenRefresher`

**Files:**
- Create: `.../Domain/Auth/TokenRefreshing.swift`, `.../Domain/Auth/APIAccessTokenSubject.swift`, `.../Data/Auth/TokenRefresher.swift`, `Marauders-ios/MaraudersTests/TokenRefresherTests.swift`, `Marauders-ios/MaraudersTests/Support/ScriptedAuthAPI.swift`

**Interfaces:**
- Produces:
  ```swift
  nonisolated protocol TokenRefreshing: Sendable {
      /// A token to use instead of `rejectedAccessToken`, which the Worker answered with 401.
      func refreshedAccessToken(replacing rejectedAccessToken: String) async -> TokenRefreshOutcome
  }
  enum TokenRefreshOutcome: Sendable { case refreshed(String), rejected, unavailable(any Error) }   // refreshed carries the new access token
  nonisolated enum APIAccessTokenSubject { static func subject(of token: String) -> String? }   // the `sub` claim; same decoding as APIAccessTokenExpiry
  actor TokenRefresher: TokenRefreshing {
      init(accessTokenStore: any APIAccessTokenStore, refreshTokenStore: any APIRefreshTokenStore,
           authAPI: any AuthAPIClientProtocol, retryDelay: Duration = .seconds(1))
  }
  ```
  `ScriptedAuthAPI` (test support) implements `AuthAPIClientProtocol`: a queue of results for `refreshTokens(using:)`, an optional gate that holds each call until the test opens it, `refreshCalls` and the tokens it was given.

- [ ] **Step 1: Write the failing tests** (`TokenRefresherTests`, access tokens from `TestAccessToken.make(subject:expiresIn:)`, stores recording their events in one list; refresh tokens are 43 valid characters):
  - `manyCallersThatMeetTheSameRejectionMakeOneCall`: 8 concurrent callers with the same rejected token, the API held at its gate; after it opens, every caller gets `.refreshed(A2)`, `refreshCalls == 1`, stores hold `(A2, R2)`.
  - `aCallerWhoseTokenWasAlreadyReplacedGetsTheStoredOneWithoutACall` (same `sub`, 0 calls); `aStoredTokenOfAnotherAccountIsNeverHandedOut` (different `sub`, and an unreadable `sub` on either side) → `.rejected`, 0 calls.
  - `noStoredSessionIsRejected`; `noRefreshTokenIsRejected`; `aMalformedRefreshTokenIsRejected`; all with 0 calls and nothing written.
  - Outcomes: a pair → `.refreshed` and stores updated; `AuthAPIError.refreshRejected` → `.rejected` with the stores untouched (the refresher never clears them); `serverError(429)` and `serverError(500)` → `.unavailable` after exactly 1 call; `serverError(404)`, `serverError(405)`, `.invalidResponse` and a pair with `refreshToken == nil` → `.unavailable`, stores untouched.
  - `aTransportFailureIsRepeatedOnce` (arguments: `URLError(.timedOut)`, `serverError(502)`, `503`, `504`; `retryDelay: .zero`): the second call succeeds → `.refreshed`, 2 calls; both fail → `.unavailable` with the error, exactly 2 calls.
  - `theNewRefreshTokenIsSavedBeforeTheAccessToken` (events `[refresh, access]`); a failing access save → `.unavailable` with the new refresh token already stored; a failing refresh save → nothing else saved, `.unavailable`.
  - `aRefreshThatFinishesAfterSignOutWritesNothing` (the stores are cleared while the call is held at the gate; after release: `.rejected`, zero saves); `aRefreshThatFinishesAfterANewSignInWritesNothing` (other account's tokens stored meanwhile; they are still there afterwards, `.rejected`).
  - `aCancelledCallerDoesNotCancelTheRefresh`: cancel the calling task while the call is at the gate, open it; the stores get the new tokens and a later caller gets `.refreshed(A2)` with 1 call in total.
  - `noTokenReachesTheAppLog`: after the cases above no `AppLogStore.shared.entries` message contains any access or refresh token used in the tests.
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/TokenRefresherTests`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement.** The structure the tests pin:
  ```swift
  private var inFlight: Task<TokenRefreshOutcome, Never>?
  func refreshedAccessToken(replacing rejected: String) async -> TokenRefreshOutcome {
      if let inFlight { return await inFlight.value }
      let task = Task { await self.refresh(replacing: rejected) }   // unstructured: a caller's cancellation does not reach it
      inFlight = task
      let outcome = await task.value
      inFlight = nil
      return outcome
  }
  ```
  `refresh`: (1) read both stored tokens inside `await MainActor.run { }`; no access token → `.rejected`; an access token different from `rejected` → `.refreshed(stored)` only when both `sub`s are readable and equal, else `.rejected`; (2) no valid-format refresh token → `.rejected`; (3) call `authAPI.refreshTokens(using:)`, repeated once after `retryDelay` when the error is a `URLError`, an `HTTPClientError` or `AuthAPIError.serverError` 502/503/504; `refreshRejected` → `.rejected`, any other error → `.unavailable(error)`; a pair whose refresh token is `nil` or malformed → `.unavailable(AuthAPIError.invalidResponse)`; (4) commit inside one `await MainActor.run { }`: proceed only if the stored refresh token still equals the one that was sent (else return `.rejected`, nothing written), then `saveRefreshToken`, then `saveAccessToken`; save errors → `.unavailable(error)`. Running every store access on the MainActor is what makes the check and the writes atomic against `AuthViewModel`, whose store calls are all MainActor and synchronous. Log under `api.refresh`: `refreshed`, `rejected`, `unavailable (<error type>)`; never a token.
- [ ] **Step 4: Run** `TokenRefresherTests`. Expected: PASS.
- [ ] **Step 5: Commit** → "Add TokenRefresher: one refresh at a time, nothing written after the session changed".

### Task 11: `TokenRefreshingHTTPClient`

**Files:**
- Create: `.../Data/API/TokenRefreshingHTTPClient.swift`, `.../Data/API/URLRequest+Bearer.swift`, `Marauders-ios/MaraudersTests/TokenRefreshingHTTPClientTests.swift`, `Marauders-ios/MaraudersTests/Support/RecordingTransport.swift`, `Marauders-ios/MaraudersTests/Support/ScriptedRefresher.swift`
- Modify: `.../Data/API/RejectedSessionReportingHTTPClient.swift`

**Interfaces:**
- Consumes: Task 10 (`TokenRefreshing`, `TokenRefreshOutcome`).
- Produces:
  ```swift
  struct SessionRefreshUnavailableError: LocalizedError, Equatable {
      var errorDescription: String? { "The service is temporarily unavailable. Please try again." }
  }
  struct TokenRefreshingHTTPClient: HTTPClient {
      nonisolated init(base: any HTTPClient, refresher: any TokenRefreshing,
                       reportRejectedReplay: (@Sendable (_ accessToken: String) async -> Void)? = nil)
  }
  extension URLRequest { nonisolated var bearerToken: String? }   // the token of an `Authorization: Bearer …` header, else nil
  ```
  Test support: `RecordingTransport` is an `HTTPClient` that returns scripted responses or throws and records each request and each upload's parts; `ScriptedRefresher` is a `TokenRefreshing` with a queue of outcomes that records the tokens it was asked about (Task 14 reuses both).

- [ ] **Step 1: Write the failing tests** (a scripted refresher double and `RecordingTransport`):
  - `aResponseThatIsNot401GoesBackUntouched` (200, 404, 500) and `a401ToAGuestGoesBackUntouched` (no `Authorization` header; also an upload): the refresher is never asked.
  - `a401WithABearerIsReplayedOnceWithTheNewToken`: transport `[401, 200]`, refresher `.refreshed("new")` → result 200; the refresher was asked with `"old"`; the second request equals the first except `Authorization: Bearer new`; exactly two transport requests.
  - `aReplayThatAnswersAnythingIsReturnedAsIs` (404, 500; no second refresh).
  - `aReplayRejectedAgainReportsTheNewTokenAndReturnsThe401`: `[401, 401]` → result 401, `reportRejectedReplay` called once with `"new"`, no third request.
  - `aRejectedRefreshReturnsTheOriginal401WithoutReplaying`: `.rejected` → 401, one transport request, no report call.
  - `anUnavailableRefreshThrowsAndNeverShowsA401`: `.unavailable(AuthAPIError.serverError(503))` and `.unavailable(AuthAPIError.invalidResponse)` throw `SessionRefreshUnavailableError`; `.unavailable(URLError(.notConnectedToInternet))` rethrows that same `URLError`; one transport request each.
  - `anUploadIsReplayedWithTheSamePartsAndTheNewToken`: two parts (a field and a file), `[401, 200]` → the second upload carries identical parts and the new header.
  - `fiveRejectedRequestsMakeOneRefreshAndFiveReplays`: the real `TokenRefresher` over memory stores and a scripted auth API; five concurrent requests carrying the same token all get 401 first → one `refreshTokens` call, five replays with the same new token, five 200s.
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/TokenRefreshingHTTPClientTests -only-testing:MaraudersTests/RejectedSessionReportingTests`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement** with one private helper shared by `data` and `upload` (it takes the "perform" closure, so the upload replay reuses the same parts), nonisolated like `RetryingHTTPClient`. The logic is the spec's "A 401, step by step". `RejectedSessionReportingHTTPClient` switches to `URLRequest.bearerToken` (its private copy goes), behavior unchanged.
- [ ] **Step 4: Run** the suites above. Expected: PASS.
- [ ] **Step 5: Commit** → "Replay a rejected request once with a refreshed token".

### Task 12: Public reads fall back to a guest when the session is unavailable

**Files:**
- Create: `.../Data/API/HTTPClient+GuestFallback.swift`, `Marauders-ios/MaraudersTests/GuestFallbackTests.swift`
- Modify: `.../Data/API/FeedAPIClient.swift` (the 401 block in `performFetchFeed`), `.../Data/API/CommentsAPIClient.swift` (`fetchComments`), `.../Data/API/UserProfileAPIClient.swift` (`fetchPublicProfile`), and their existing test files

**Interfaces:**
- Consumes: Task 11 (`SessionRefreshUnavailableError`, `URLRequest.bearerToken`).
- Produces: `extension HTTPClient { func dataFallingBackToGuest(_ request: URLRequest, logCategory: String) async throws -> HTTPClientResponse }`: a request without a bearer token is sent as it is; otherwise it is sent, and when the answer is 401 **or** the call throws `SessionRefreshUnavailableError`, it is sent once more with the `Authorization` header removed. Any other error propagates unchanged.

- [ ] **Step 1: Write the failing tests.** `GuestFallbackTests` (over `RecordingTransport`): `a401FallsBackToAGuestRead`; `anUnavailableSessionFallsBackToAGuestRead` (the request with a bearer throws `SessionRefreshUnavailableError`, the second has no `Authorization` header and its answer is returned); `aTransportErrorIsNotTurnedIntoAGuestRead` (`URLError` propagates, one request); `aGuestRequestIsSentOnce`. Per client, in its existing test file: `anUnavailableSessionStillLoadsTheFeed`, `anUnavailableSessionStillLoadsTheComments`, `anUnavailableSessionStillLoadsAPublicProfile`; and in `CommentsAPIClientTests` `postingWithAnUnavailableSessionSurfacesTheServiceError` (`SessionRefreshUnavailableError` propagates, not `signInRequired`).
- [ ] **Step 2: Run** `GuestFallbackTests` and the three client suites. Expected: FAIL.
- [ ] **Step 3: Implement** the helper and replace the three inline "401 then read as guest" blocks with it, keeping each client's log category and the log line wording (`session rejected, reading as guest`; for the typed error `session unavailable, reading as guest`). The feed's own transient-failure retry is untouched.
- [ ] **Step 4: Run** `GuestFallbackTests`, `FeedAPIClientTests`, `CommentsAPIClientTests`, `UserProfileAPIClientTests`. Expected: PASS (the existing 401-fallback tests included).
- [ ] **Step 5: Commit** → "Read as a guest when the session cannot be refreshed".

### Task 13: Startup cache keyed by the account, not the token

**Files:**
- Modify: `.../Data/Services/FeedStartupCache.swift` (`SessionFeedStartupCache.sessionCache()`), `.../Data/API/DubbedAudioCacheClient.swift` (`reporterID`), `Marauders-ios/MaraudersTests/FeedStartupCacheTests.swift`

**Interfaces:**
- Consumes: `APIAccessTokenSubject` (Task 10).

- [ ] **Step 1: Write the failing tests** (`SessionFeedStartupCache` with a mutable `tokenProvider`, a temp directory): `twoTokensOfOneAccountShareACache` (store with token A1, switch to A2 with the same `sub`, `cachedVideos()` still returns them); `anotherAccountGetsItsOwnCache`; `aGuestHasItsOwnCache`; `aTokenWithoutAReadableSubjectStillGetsItsOwnCache` (two different opaque strings stay apart, as today).
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/FeedStartupCacheTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** The folder name is the SHA-256 of the token's `sub` when it can be read, of the whole token otherwise, of `"guest"` for no token. `reporterID` reads the claim through `APIAccessTokenSubject` and keeps returning `"signed-in"` when it cannot.
- [ ] **Step 4: Run** `FeedStartupCacheTests` and the suites that use `reporterID` (grep for it). Expected: PASS.
- [ ] **Step 5: Commit** → "Keep the startup feed per account so a refresh does not empty it".

### Task 14: Composition: where the layers sit, one refresher for the process

**Files:**
- Create: `.../Composition/APITransportComposition.swift`, `Marauders-ios/MaraudersTests/APITransportCompositionTests.swift`
- Modify: `.../Composition/AppDependencyContainer.swift`

**Interfaces:**
- Consumes: Tasks 6, 8, 10, 11.
- Produces:
  ```swift
  enum APITransportComposition {
      /// Every client but the feed: reporter ← refresh ← retry ← base. A replay also gets the retry layer.
      nonisolated static func api(base: any HTTPClient, refresher: any TokenRefreshing,
                                  reportRejected: @escaping @Sendable (String) async -> Void) -> any HTTPClient
      /// The feed repeats its own reads: reporter ← refresh ← base.
      nonisolated static func feed(base: any HTTPClient, refresher: any TokenRefreshing,
                                   reportRejected: @escaping @Sendable (String) async -> Void) -> any HTTPClient
      /// No session-ending reporter (background location, dubbed audio): refresh ← base.
      nonisolated static func quiet(base: any HTTPClient, refresher: any TokenRefreshing) -> any HTTPClient
  }
  // AppDependencyContainer: static let tokenRefresher: TokenRefresher   // Keychain stores + AuthAPIClient()
  ```
  `reportRejected` goes to the outer reporter and to the refresh layer's `reportRejectedReplay`.

- [ ] **Step 1: Write the failing tests** (`RecordingTransport` as the base, a scripted refresher, a real `AuthViewModel` over memory stores where noted):
  - `theApiStackRetriesAReplay`: GET `[401, 503, 200]` with `.refreshed("new")` → result 200, three base requests (the replay went through the retry layer).
  - `aFreshSessionIsNeverReported`: `[401, 200]` with `.refreshed` → `reportRejected` never called.
  - `aRejectedRefreshReportsTheOldToken`: `.rejected` → called once with the old token, result 401.
  - `aReplayRejectedAgainEndsTheSessionWithTheNewToken` (end to end): memory stores `(A1, R1)`, the real `TokenRefresher` with a scripted API answering `(A2, R2)`, base `[401, 401]`, `reportRejected` = `viewModel.handleRejectedAccessToken`; afterwards `isSignedIn == false` and all three stores are empty.
  - `theFeedStackHasNoRetryLayer`: `[401, 503]` with `.refreshed` → the 503 is returned after one replay (two base requests).
  - `theQuietStackRefreshesAndReplays`: `[401, 200]` with `.refreshed("new")` → 200 with the new header on the second request (a background location report survives an expired 1-day token).
  - `theQuietStackStopsAt401`: `.rejected` and a replayed 401 both reach the caller as 401 (what `BackgroundLocationMonitor` reads as "stop sharing"); there is no reporter to call.
  - `aRejectedUITestSessionStillEndsOnThe401`: `UITestRejectedSession` + `UITestRejectingHTTPClient` + a real refresher over those stores (no refresh token) + `api` stack + `AuthViewModel` → the first request signs the viewer out.
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/APITransportCompositionTests`. Expected: FAIL (does not compile).
- [ ] **Step 3: Implement the stacks**, then wire the container (read `AppDependencyContainer.swift` lines ~55-90, ~240-250 first): add `static let tokenRefresher = TokenRefresher(accessTokenStore: KeychainAPIAccessTokenStore(), refreshTokenStore: KeychainAPIRefreshTokenStore(), authAPI: AuthAPIClient())`; in `init` pick the refresh store beside the session and token stores (`UITestRejectedSession` in the rejected UI-test mode, Keychain otherwise) and build the container's refresher over the same stores in that UI-test mode, `Self.tokenRefresher` otherwise; pass `refreshTokenStore` to `AuthViewModel`; build `transport` with `.api` and `feedTransport` with `.feed`; `backgroundLocationMonitor`'s `UserLocationAPIClient` gets `.quiet(base: URLSessionHTTPClient(), refresher: tokenRefresher)`; `dubbedAudioCache` is created in `init` with `DubbedAudioCacheClient(client: .quiet(base: URLSessionHTTPClient(), refresher: Self.tokenRefresher))` (still no reporter: the 2026-10-31 decision stands).
- [ ] **Step 4: Run** `APITransportCompositionTests`, `AppDependencyContainerWiringTests`, `SessionExpiryTests`, then the whole unit suite (`-only-testing:MaraudersTests`). Expected: PASS.
- [ ] **Step 5: Commit** → "Compose the refresh layer into every API transport and share one refresher".

### Task 15: Debug-only fault for the real rotation check

**Files:**
- Create: `.../Composition/DebugSessionFault.swift`, `Marauders-ios/MaraudersTests/DebugSessionFaultTests.swift`
- Modify: `.../App/MaraudersApp.swift`

**Interfaces:**
- Produces (all `#if DEBUG`):
  ```swift
  enum DebugSessionFault {
      static let launchArgument = "DEBUG_INVALIDATE_ACCESS_TOKEN"
      /// With the launch argument present and an access token stored, replaces it with one the Worker will reject
      /// (valid format, not a real JWT). Returns whether it did.
      @discardableResult
      static func applyIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
                                   tokenStore: any APIAccessTokenStore = KeychainAPIAccessTokenStore()) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests:** `withoutTheArgumentNothingChanges`; `withTheArgumentAStoredTokenIsReplacedByAValidFormatToken` (differs from the old one, `APIAccessTokenFormat.isValid` is true, `APIAccessTokenExpiry.isExpired` is true so it can never pass for a live one); `withTheArgumentAndNoTokenNothingIsCreated`.
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/DebugSessionFaultTests`. Expected: FAIL.
- [ ] **Step 3: Implement**, and call it in `MaraudersApp.init()` right after `InstallationSessionGuard.bootstrap()`, inside `#if DEBUG`.
- [ ] **Step 4: Run** the suite. Expected: PASS.
- [ ] **Step 5: Commit** → "Add a Debug-only launch argument that invalidates the access token".

---

## Part 3: Docs, verification, rollout

### Task 16: Documentation

**Files:**
- Create: `docs/adr/007-token-refresh.md`
- Modify: `ARCHITECTURE.md`, `README.md`, `docs/ci-cd.md`, `docs/adr/README.md`, `docs/adr/002-ios-concurrency.md`

- [ ] **Step 1: Write ADR 007** (the style of `006-feed-get-retry.md`): context (30-day stateless token, any 401 ends the session), decision (rotating refresh tokens with server state, opt-in flag, 1-day access token, 90-day sliding refresh token, 60 s leeway), alternatives (renew the JWT with itself, re-run Sign in with Apple), consequences: deploy order (migration, Worker, then the TestFlight build), a rolled-back Worker answers 405 which the app reads as unavailable, the lost-response residual and the additive attempt-id upgrade, no purge of old rows yet, no refresh at launch, the startup cache keyed by `sub`. Add its line to `docs/adr/README.md`; add `TokenRefresher` as a further actor to ADR-002.
- [ ] **Step 2: Update `ARCHITECTURE.md`** (find each place with `grep -n` on the quoted phrase): the `/v1/auth/apple` and `/v1/auth/dev` rows (answer `{ accessToken, refreshToken? }`, the `supportsRefreshTokens` flag, 1 day vs 30 days) and two new rows for `/v1/auth/refresh` and `/v1/auth/signout`; the `auth` row of the rate-limit table (now four routes); "Data model" (the `refresh_tokens` table); "Session end", "While closed" and "Signing out" (revoke inside the 3 s window, sharing first, then revoke; a rejection or Apple revocation calls nothing); the HTTP section "A 401 ends the session" (refresh, replay once, the three outcomes, where the layers sit, the reporter's new-token rule, `DubbedAudioCacheClient` now has the refresh layer but no reporter); the `UITEST_REJECTED_SESSION` row (in-memory refresh store with no token, so the refresh is `.rejected`); the actor table and its "Five" count (a sixth, `TokenRefresher`); the Tests section (`npm run test:auth-refresh`; the unit test count from the `grep` in "How to run things", and the file count).
- [ ] **Step 3: Add `test:auth-refresh`** wherever the backend test commands are listed: `README.md` (a Thai table of test commands: add a row in Thai), `docs/ci-cd.md` (a Thai list), and the two `ARCHITECTURE.md` places that name `test:follows` (the npm commands table and the Tests bullet). Find them with `grep -rn 'test:follows' README.md ARCHITECTURE.md docs`.
- [ ] **Step 4: Check the docs against the code:** every file and type named exists (`ls` / `grep`); no section still says a 401 ends the session without a refresh attempt.
- [ ] **Step 5: Commit** the named files → "Document token refresh (ADR 007 and the architecture notes)".

### Task 17: Whole-system verification

- [ ] **Step 1: Worker.** In `backend/`: `npm run typecheck && npm run test:auth-refresh && npm run test:dev-auth && npm run test:follows && npm run test:comments && npm run test:likes && npm run test:feed && npm run test:dubbed-audio`. Expected: all PASS.
- [ ] **Step 2: Unit tests on the phone**, the whole `MaraudersTests` target. Expected: every test passes (897 before this work plus the new ones).
- [ ] **Step 3: UI tests on the phone** (Do Not Disturb on, phone unlocked, detached run as in the project memory note; a notification banner over a tapped button is a known flake: re-run that test alone). Expected: 52 of 52, with the rejected-session tests included.
- [ ] **Step 4: Layer checker:** `sh Marauders-ios/Scripts/check-layers.sh`. Expected: no output.
- [ ] **Step 5: Unsigned Release archive:** `xcodebuild archive -project Marauders-ios/Marauders.xcodeproj -scheme Marauders -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/dd-release" -archivePath "$SCRATCH/Marauders.xcarchive" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`. Expected: `** ARCHIVE SUCCEEDED **`, and `strings` on the app binary inside the archive finds no `DEBUG_INVALIDATE_ACCESS_TOKEN`.
- [ ] **Step 6: Logs and tree.** `grep -rn "AppLog\.\|console\." Marauders-ios/Marauders/Data/Auth/TokenRefresher.swift Marauders-ios/Marauders/Data/API/TokenRefreshingHTTPClient.swift Marauders-ios/Marauders/Data/API/AuthAPIClient.swift backend/src/routes/authRefresh.ts backend/src/db/refreshTokens.ts` shows no token or hash in any message. `git status --short` lists only this work's files plus the untouched `RetryingHTTPClient.swift` edit.
- [ ] **Step 7: Review.** Run a whole-branch review (`superpowers:requesting-code-review`) and fix what it confirms.

### Task 18: Rollout (every step is the owner's call)

- [ ] **Step 1: Record the rollback target.** From `backend/`: `npx wrangler deployments list` and note the current version id.
- [ ] **Step 2: Ask the owner:** run migration 022 (`cd backend && npm run db:migrate`; it replays all files and ends with `migration complete`, the new table's `CREATE` among the `ok:` lines). The running Worker does not notice the new table.
- [ ] **Step 3: Ask the owner:** deploy the Worker (`cd backend && npm run deploy`), only after step 2; note the new version id. Then smoke-check with `API_BASE` set to the Worker's base URL and `T=$(printf 'A%.0s' $(seq 1 43))`:
  ```bash
  curl -s -w ' %{http_code}\n' -X POST "$API_BASE/v1/auth/refresh" -H 'content-type: application/json' -d '{}'
  curl -s -w ' %{http_code}\n' -X POST "$API_BASE/v1/auth/refresh" -H 'content-type: application/json' -d "{\"refreshToken\":\"$T\"}"
  curl -s -o /dev/null -w '%{http_code}\n' -X POST "$API_BASE/v1/auth/signout" -H 'content-type: application/json' -d "{\"refreshToken\":\"$T\"}"
  ```
  Expected: 400; `{"error":"invalid refresh token"} 401`; 204.
- [ ] **Step 4: One real rotation on the phone** (needs steps 2 and 3 done). Install a Debug build on the iPhone, sign in with Apple, then relaunch with the launch argument `DEBUG_INVALIDATE_ACCESS_TOKEN` (an Xcode scheme argument or `xcrun devicectl device process launch`). Expected: the feed loads, the viewer is still signed in, and the app log shows an `api.refresh` `refreshed` line. Launch with the argument a second time: it refreshes again, which shows the first rotation's new refresh token was saved.
- [ ] **Step 5: Tell the owner what is left:** a push builds nothing; users get the app change only through a TestFlight build, which the owner starts (Jenkins, Build Now), and until a viewer signs in again on that build they hold a 30-day token and behave as today. Rolling the Worker back leaves the table in place and the app reads the 405 as unavailable.
