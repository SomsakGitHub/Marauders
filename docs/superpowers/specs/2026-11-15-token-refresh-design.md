# Token refresh: design

Date: 2026-11-15
Status: approved by the owner on 2026-11-15. Nothing in this document has been built yet; the implementation plan is `docs/superpowers/plans/2026-11-15-token-refresh.md`.
Topic: Networking (URLSession, error handling, retry, token refresh). Retry shipped in `3ea73b4`; this is the last part.

## Intent

A signed-in viewer is signed out 30 days after they signed in, and any 401 on a request that carried their token signs
them out at once. The Worker issues one stateless 30-day JWT and has no way to renew it; the app ends the session in
`AuthViewModel.restoreSession()` (when `exp` has passed) and `AuthViewModel.handleRejectedAccessToken(_:)` (on a 401,
reported by `RejectedSessionReportingHTTPClient`).

Add token refresh so a session ends only when the viewer ends it, when the Worker really rejects the session, or when
it has sat idle for the refresh token's lifetime, and so that a flaky network never ends it. It also completes the
Networking topic the owner is working through (URLSession, error handling, retry, token refresh).

## Goals

- A viewer who opens the app at least once every 90 days is never asked to sign in again because a token ran out.
- Several requests that get 401 together cause one refresh, then each is repeated once with the new token.
- A refresh that cannot be completed (offline, timeout, 429, 5xx, a route that is not there) never signs the viewer out
  and never reaches a caller as a 401. A response lost after the Worker had already rotated the token is covered only as
  far as the leeway reaches (see "Lost responses").
- Signing out revokes the refresh token on the Worker (best effort). Using a spent refresh token again ends its whole
  family, because that looks like theft.
- Sharing location while the app is closed keeps working with a short access token.
- App builds that are already installed keep working after the Worker is deployed.

## Non-goals

- No refresh at launch and none before the access token expires. Only a 401 triggers a refresh.
- No upgrade path for the 30-day tokens already issued. They run to their own `exp`, as today.
- No "sign out everywhere", device list, or binding a token to a device.
- No revocation list for access tokens; they stay stateless.
- No change to `RetryingHTTPClient`, the feed's own retry, `Retry-After` handling, or a shared error type for the API
  clients. Those are separate follow-ups.
- No UI change and no new strings.

## Anti-goals (a failure even if the happy path works)

- A viewer signed out by a 5xx, a 429, a missing route or being offline, or by a lost response that a quick retry would
  have recovered.
- Two refreshes racing, so the Worker sees a spent token and revokes the family.
- Background location sharing quietly stopping once the first access token expires.
- A refresh that finishes after sign-out and writes the tokens back.
- Any token, or a hash of one, in `AppLog` or in a Worker log line.

## How it works today

Worker (`backend/`):
- `src/auth/accessToken.ts`: HS256 JWT, `sub` = user id, `ACCESS_TOKEN_TTL = "30d"`. `authenticateBearerRequest` only
  verifies the signature and `exp`; there is no database read per request.
- `src/routes/authApple.ts` and `src/routes/authDev.ts` answer `{ accessToken }`. `src/index.ts` routes them and gives
  them the `auth` rate limit (30 per 60 s per client IP, Neon fixed window plus the Cloudflare binding).
- `src/db/*.ts` talk to Neon one statement per request (`neon(databaseUrl)`), so anything that must be atomic is one SQL
  statement (see the `WITH prev AS (...) UPDATE` in `setUserAvatar`).
- `scripts/migrate.mjs` lists every migration file by name and replays all of them on each run, so a migration must be
  idempotent. It splits on `;` before stripping `--` comments, so a `;` inside a comment breaks the file.
- Tests: `test/*.test.ts` bundled by `scripts/test-*.mjs` (esbuild, then `node --test`) with `@neondatabase/serverless`
  swapped for the programmable fake in `test/fakes/neon.ts`. No real SQL runs there.

App (`Marauders-ios/Marauders/`):
- `Composition/AppDependencyContainer.swift` builds `RejectedSessionReportingHTTPClient(base: RetryingHTTPClient(base:
  URLSessionHTTPClient()))` for every API client except the feed, which gets the reporter over the plain transport (it
  repeats its own reads).
- `RejectedSessionReportingHTTPClient` reports any 401 to a request that carried a Bearer token, before the response goes
  back. `AuthViewModel.handleRejectedAccessToken(_:)` ends the session only if that token is still the stored one.
- `static let backgroundLocationMonitor` is built before any container exists, with a bare `URLSessionHTTPClient()` and
  its own `KeychainAPIAccessTokenStore()`. A 401 there makes `BackgroundLocationMonitor` stop sharing.
- `DubbedAudioCacheClient` is built by the container outside that stack; the owner chose on 2026-10-31 that its 401s do
  not end the session.
- `Data/Auth/KeychainAPIAccessTokenStore` (service `com.somsak.Marauders.auth`, account `apiAccessToken`,
  `AfterFirstUnlockThisDeviceOnly`, returns nil until `InstallationSessionGuard.isReady`). `InstallationSessionGuard`
  clears the stores once per install, because the Keychain outlives an uninstall.
- `SessionFeedStartupCache` keeps the startup feed per session, keyed by a SHA-256 of the whole access token.
- `UITestRejectedSession` is the in-memory store pair the rejected-session UI tests use.

## Approaches

**A. Rotating refresh token with server-side state (chosen).** A `refresh_tokens` table holds a hash of each token, its
family and its state. Each use rotates it; reuse of a spent token revokes the family. Revocable, detects theft, the
usual design. Cost: a migration, three Worker changes and a Worker deploy before the app can use it.

**B. Renew the JWT with itself (not chosen).** `POST /v1/auth/renew` takes a still-valid (or recently expired) access
token and returns a fresh one. No migration. But the one token is both key and renewal ticket, so a leaked token renews
forever, nothing can be revoked and nothing detects reuse, and accepting expired tokens quietly lengthens their life.

Not chosen either: re-running Sign in with Apple to mint a new token. As far as I know it needs the system sheet, so it
cannot happen under a request that is already in flight (not tried on a device).

## Design: Worker

### Data

`backend/sql/022_refresh_tokens.sql`, added to the list in `scripts/migrate.mjs`, idempotent:

```sql
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_users (id) ON DELETE CASCADE,
    family_id UUID NOT NULL,
    token_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS refresh_tokens_token_hash_uidx ON refresh_tokens (token_hash);
CREATE INDEX IF NOT EXISTS refresh_tokens_family_idx ON refresh_tokens (family_id);
```

### Tokens

- Refresh token: 32 random bytes from `crypto.getRandomValues`, base64url. Only its SHA-256 (hex) is stored. It is valid
  for 90 days from the moment it is issued, so every rotation restarts the 90 days (sliding).
- Access token: the same JWT as today. 1 day for a client that asks for a refresh token, 30 days (today's) for a client
  that does not, so installed builds, which cannot refresh, are not signed out daily.

### Routes

`POST /v1/auth/apple` and `POST /v1/auth/dev`: the body gains an optional `supportsRefreshTokens: true`. Without it the
answer is today's `{ accessToken }` with a 30-day token. With it the Worker starts a new family and answers
`{ accessToken, refreshToken }` with a 1-day access token.

`POST /v1/auth/refresh`, body `{ refreshToken }`, answer `{ accessToken, refreshToken }`:
1. A body or token of the wrong shape: 400.
2. Hash it and look the row up. No row, revoked, or past `expires_at`: 401.
3. Row never used: in one statement mark it used and insert its successor in the same family. 200.
4. Row used less than the leeway ago (60 s, a constant): the first answer was probably lost. Insert another successor in
   the same family. 200.
5. Row used longer ago: reuse. Set `revoked_at` on every row of the family. 401.

All 401s carry the same body, so the answer says nothing about which check failed. The route shares the `auth` per-IP
limit with sign-in. 429 and 5xx are answers the app must read as "try later", not as "rejected".

`POST /v1/auth/signout`, body `{ refreshToken }`: revokes the token's whole family and answers 204, also for an unknown,
expired or already revoked token (nothing to learn from it). A malformed body is 400. It needs no Bearer token, because
the access token may well have expired.

Rotation in step 3 is one statement (a CTE that updates `used_at ... WHERE used_at IS NULL AND revoked_at IS NULL AND
expires_at > now()` and inserts from its `RETURNING`). Two requests with the same token at once: one wins the update, the
other finds the row used and takes step 4.

### Lost responses

A refresh whose answer never arrived leaves the phone holding a token the Worker has already spent. Two things recover
it: the Worker's leeway (step 4) and the refresher's own retry (see `TokenRefresher` rules), which comes about a second
later, well inside it. What they do not cover is the app being suspended or killed during the call, or no connection for
longer than the leeway, followed by a request that gets 401. That later attempt looks like reuse and ends the family, so
the viewer signs in with Apple once.

Chosen for now: accept that residual. It needs a loss at the moment of a refresh (at most once a day per device) and then
a minute without a connection. Upgrade path if it shows up in practice, additive and not built now: the app sends a random
attempt id with each refresh and keeps it with the token until an answer arrives; the Worker stores it on the spent row,
so the same token with the same attempt id gets a new successor at any age, while any other reuse still ends the family.

## Design: app

### Pieces (placed by the layer rules; no new entry in `layer-exceptions.txt`)

Domain:
- `APIRefreshTokenStore` (load, save, clear) beside `APIAccessTokenStore`, with a format check like
  `APIAccessTokenFormat`.
- Sign-in answers a pair, `AuthTokens { accessToken, refreshToken? }`, from `AuthAPIClientProtocol` and
  `DevAuthExchanging`. `refreshToken` is optional so an answer without one (an older Worker) leaves the app as it is
  today.
- `AuthAPIClientProtocol` gains the two new calls (refresh, revoke).
- A protocol for what the 401 layer needs, for example `refreshedAccessToken(replacing: String) async ->
  TokenRefreshOutcome` with `.refreshed(String)`, `.rejected`, `.unavailable(Error)`.

Data:
- `KeychainAPIRefreshTokenStore`: same service, account `apiRefreshToken`, same accessibility, same
  `InstallationSessionGuard` rule. `InstallationSessionGuard.resetIfNeeded` clears it too.
- `TokenRefresher`, an `actor` (the sixth; ADR-002 and the concurrency section of `ARCHITECTURE.md` list the actors).
- `TokenRefreshingHTTPClient`, a decorator in `Data/API`.

Presentation / Composition: `AuthViewModel`, `AppDependencyContainer`, `UITestRejectedSession` (also implements the new
store in memory).

### A 401, step by step (`TokenRefreshingHTTPClient`)

For `data` and for `upload` (an upload is replayed with the same parts; a 401 means nothing was applied):
1. Send. Anything but a 401, or a 401 to a request without a Bearer token (a guest), goes back untouched.
2. Ask the refresher for a token to replace the rejected one.
3. `.refreshed(token)`: send the same request once more with `Authorization: Bearer <token>` and return that answer,
   whatever it is.
4. `.rejected`: return the original 401, so the session ends exactly as today.
5. `.unavailable`: throw. A transport error from the refresh call is thrown as it is, so the feed's own
   transient-failure retry still applies. Any other failure (429, 5xx, a route that answers 404 or 405, a malformed 200)
   is thrown as one typed error (`SessionRefreshUnavailableError`, name up to the builder). A caller never sees a 401, so
   nobody is signed out. The reads that today read as a guest on a 401 (`FeedAPIClient`, `CommentsAPIClient.fetchComments`,
   the public profile in `UserProfileAPIClient`) read as a guest on the typed error too, so a refresh route that
   misbehaves never keeps clips from the viewer. Every other caller surfaces it as a service error ("try again").

### `TokenRefresher` rules

- One refresh at a time. Callers that arrive while one is running wait for the same result.
- First check the stores. If the stored access token is no longer the rejected one, another caller already refreshed:
  return it without a network call. If there is no stored session at all, return `.rejected`.
- No stored refresh token (a session from before this change): `.rejected`. That is today's behavior.
- Outcome of the call: 200 gives `.refreshed`; 400 and 401 give `.rejected`; anything else, including a transport error
  or a malformed 200, gives `.unavailable`.
- The call runs in a task the actor owns, not in a caller's task. A caller that goes away (a SwiftUI `.task` ending, a
  cancelled request) must not cancel it, because a refresh cut off after the Worker rotated is the lost response above.
  Callers only wait for its result.
- A call that fails in transport, or that the Worker answers with 502, 503 or 504, is repeated once after about a second,
  inside the leeway. Not for 429. A second failure is `.unavailable`.
- Save the new refresh token first, then the new access token. A crash between them leaves a spent access token and a
  good refresh token, which recovers; the opposite order leaves a spent refresh token.
- A refresh that finishes after the viewer signed out, or signed in again, writes nothing. The stores are checked before
  the writes, and the writes and the sign-out clear must not be able to interleave (route both through the actor, or lock
  the stores; the builder picks).
- One refresher per process. The container and the static background monitor use the same instance.
- It never logs a token.

### Where the decorator sits

- Every client the container builds, except the feed: `RejectedSessionReportingHTTPClient(base:
  TokenRefreshingHTTPClient(base: RetryingHTTPClient(base: URLSessionHTTPClient())))`. A replay also gets the retry layer.
- The feed: the same without `RetryingHTTPClient`, as today.
- `BackgroundLocationMonitor`: `TokenRefreshingHTTPClient` over the bare client, with the shared refresher and no
  reporter. When the refresh is rejected the 401 reaches the monitor, which stops sharing as it does now; the next launch
  ends the session through the foreground path.
- `DubbedAudioCacheClient`: the decorator too, still without the reporter (the owner's 2026-10-31 decision stands: its
  401s do not end the session). Without it a 1-day token would make its calls fail daily until another request refreshed.

Invariant for whoever writes the decorator and the reporter: a session ends only when (a) a 401 arrives and there is no
refresh token to try, (b) the Worker rejects the refresh token, or (c) a request repeated with a fresh token is rejected
again. It still ends in one place, `AuthViewModel.handleRejectedAccessToken`, and the token it is given must be the one
the rejected attempt carried. Today the reporter reads the token from the request it was handed, which after a replay is
the old one and would be ignored as stale; case (c) needs the reporter, or the decorator, to report the new token.

### Launch, sign-in, sign-out

- `restoreSession()` treats a stored refresh token as a live session: an expired access token is no longer a reason to
  clear it. No refresh runs at launch; the first request that gets a 401 does it. Expired access token with no refresh
  token still signs out, as today. The Apple credential-state check stays.
- After Apple answers, `restoreSession()` must not compare the access token, because a refresh can change it meanwhile:
  the feed's first request (`VideoFeedView`'s `.task`) runs concurrently with `restoreSession()` (`ContentView`'s
  `.task`), and an expired access token makes that request refresh. It compares a session generation kept in
  `AuthViewModel` instead, bumped by sign-in (Apple and dev), sign-out, a rejection and `clearStoredSession`, never by a
  refresh (`ProfileViewModel.sessionGeneration` is the precedent). With the token compare, the guard would return early
  and leave `isSignedIn` false for a live session, and `ContentView` would then call
  `friendLocationsViewModel.reset(signedOut: true)`, which switches background sharing off and persists that.
  In `SessionExpiryTests`, `aRejectionWhileAppleIsAnsweringIsNotUndone` keeps its meaning;
  `aNewSignInWhileAppleIsAnsweringIsNotUndone` writes the token store directly, so it must sign in through the view
  model; add a test where a refresh happens while Apple is answering and the session survives.
- Sign-in sends `supportsRefreshTokens: true`, saves the refresh token (if the answer has one) and then the access token.
- Sign-out switches location sharing off, as now, and revokes the refresh token on the Worker in the same best-effort
  window (the same 3-second bound; neither holds the sign-out back). Then both tokens are cleared locally. A session that
  ends by rejection or by an Apple revocation clears both tokens locally and calls nothing.
- `handleRejectedAccessToken` and `clearStoredSession` clear the refresh token too.

### Other readers of the access token

- `SessionFeedStartupCache` keys its folder by a hash of the whole token, so it would start empty after every refresh.
  Key it by the token's `sub` instead (the same account keeps its cache). `DubbedAudioCacheClient` already reads `sub`
  by hand; one shared reader is fine.
- `handleRejectedAccessToken`'s compare (`tokenStore.loadAccessToken() == accessToken`) stays right: a late 401 for a token
  that has since been replaced changes nothing. The same compare in `restoreSession()` does not (see Launch, above).

## Rollout

1. Run migration 022 (`npm run db:migrate` from `backend/`). The table is new, so the running Worker does not notice.
2. Deploy the Worker. It is compatible with every installed build, which never sends `supportsRefreshTokens`.
3. Ship the app in a TestFlight build (a push builds nothing; the owner starts Jenkins). Until a viewer signs in again on
   the new build they have a 30-day token and no refresh token, and behave as today.

Steps 1 and 2 are the owner's call each, asked separately and in that order (a Worker that expects the table must not go
out before it exists). Note the deployed Worker version before step 2 as the rollback target. Rolling the Worker back
leaves the table in place. After the app has shipped, though, the old Worker answers 405 to `POST /v1/auth/refresh`, which
counts as unavailable: nobody is signed out, public reads fall back to guest and writes fail with a service error until the
Worker is deployed again.

## Verification

- Worker (`node --test`, fake Neon): sign-in with and without the flag; refresh; the leeway; reuse revoking the family;
  expired, revoked and unknown tokens; malformed bodies; sign-out; the new routes sit under the `auth` rate limit.
- The rotation statements (first use, second use inside the leeway, reuse after it, expired, revoked, sign-out) run against
  PGlite, as was done for the follow lists. The fake Neon cannot show that SQL is right. PGlite has one connection, so it
  cannot show two simultaneous uses; that case rests on Postgres's READ COMMITTED behavior (the second `UPDATE` waits for
  the first and re-checks `used_at IS NULL`), and one process never causes it because the refresher is single-flight. A
  real two-connection test would need a throwaway Neon branch or a local Postgres; not planned. PGlite is not in the repo,
  so installing it in a scratch folder is a download that the owner approves when it comes to it.
- App (Swift Testing): the refresher (N concurrent callers make one call, the stored-token shortcut, each outcome, the save
  order, nothing written after a sign-out); the decorator (replay with the new header, a guest untouched, `.unavailable`
  never a 401, an upload replayed with its parts, a second 401 ends the session with the new token); `AuthViewModel`
  (sign-in, sign-out, rejected, restore with and without a refresh token); the Keychain store and the installation guard;
  the startup cache key; the background monitor path.
- The 891 unit and 52 UI tests stay green on the phone, and the layer checker shows no new warning.
- One real rotation against the deployed Worker, after the owner has approved steps 1 and 2: sign in with Apple on the
  phone, then launch a Debug build with a launch argument that replaces the stored access token with an invalid one (the
  code is `#if DEBUG` and absent from Release), so the next request takes the real 401, refresh and replay path. The dev
  sign-in route is meant to stay off in production and an access token lasts a day, so there is no other quick way.

## Documentation to update

`ARCHITECTURE.md` (the auth rows of the route table, the `auth` row of the rate-limit table, "Session end", "While closed",
"Signing out", the HTTP section "A 401 ends the session", the `UITEST_REJECTED_SESSION` row, the actor list), a new
`docs/adr/007-token-refresh.md` with its line in `docs/adr/README.md`, and the actor mention in ADR-002.

## Calls I made (the owner may overrule any of them)

- Access token 1 day (the first draft said 1 hour), refresh token 90 days sliding, leeway 60 s.
- Old clients keep a 30-day token through an opt-in flag, instead of every client getting 1 day.
- No refresh at launch: a stored refresh token is enough to count as signed in.
- `DubbedAudioCacheClient` gets the refresh layer but still no session-ending reporter.
- The startup cache moves from a per-token key to a per-account key.
- Sign-out revokes best effort; a failed revoke leaves the token alive on the Worker until it expires.
- Lost responses: the 60 s leeway plus the refresher's own quick retry, with the residual stated above, not an attempt id.
- A refresh that is unavailable lets the three public reads fall back to guest and turns everything else into a service
  error; a missing route (a rolled-back Worker) counts as unavailable, never as rejected.
- `restoreSession()` compares a session generation in `AuthViewModel`, not the access token; one existing test is rewritten.
- The refresh runs in a task the refresher owns, so a cancelled caller cannot cut it off.
- Verification: PGlite for the sequential cases only, no two-connection test, and a Debug-only launch argument for the one
  real rotation.

## Left to the builder

Names, file layout, and whether the 401 handling extends `RejectedSessionReportingHTTPClient` or sits beside it; how the
refresher and the sign-out clear are serialized; how a test makes an access token expire; whether the Worker purges old
rows; the exact wording of log lines (never with a token in them).
