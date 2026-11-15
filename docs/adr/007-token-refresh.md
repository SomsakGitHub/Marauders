# ADR-007: Rotating refresh tokens, and a refresh under every 401

**Status:** Accepted  
**Date:** 2026-11-15  
**Scope:** `POST /v1/auth/apple`, `/v1/auth/dev`, `/v1/auth/refresh`, `/v1/auth/signout`, the `refresh_tokens` table, `TokenRefresher`, `TokenRefreshingHTTPClient`, sign-out

## Context

The Worker issued one stateless **30-day** JWT at sign-in and had no way to renew it, so a viewer was signed out 30 days after signing in. Any **401** to a request that carried the token ended the session at once (`AuthViewModel.handleRejectedAccessToken`). Nothing could be revoked: a sign out only cleared the phone, and a stolen token worked until its `exp`.

## Decision

- **Rotating refresh tokens with state on the Worker.** `refresh_tokens` (migration 022) keeps the SHA-256 of every token with its family, `expires_at`, `used_at` and `revoked_at`. A refresh token is 32 random bytes, base64url (43 characters), valid for **90 days from the moment it is issued**, so each rotation restarts the 90 days (sliding).
- **Opt-in.** A client that sends `supportsRefreshTokens: true` to `/v1/auth/apple` or `/v1/auth/dev` gets `{ accessToken, refreshToken }` with a **1-day** access token. Any other client gets today's `{ accessToken }` with a 30-day one, so builds that are already installed are not signed out daily.
- **`POST /v1/auth/refresh { refreshToken }`** answers a new pair. One SQL statement spends the token and inserts its successor in the same family. A token presented again within a **60 s leeway** (its answer was probably lost) gets another successor; reuse after that revokes the whole family. Every token the Worker cannot accept (unknown, revoked, expired, reused) answers the same **401** `{"error":"invalid refresh token"}`; a malformed body is 400; a database failure is 500, never 401. **`POST /v1/auth/signout { refreshToken }`** revokes the family and answers 204, also for a token it does not know. Both routes share the `auth` rate limit (30 / 60 s per IP) with sign-in.
- **The 401 is healed under the request.** `TokenRefreshingHTTPClient` asks `TokenRefresher` (an actor; one refresh at a time, every caller shares its answer) for a token to replace the rejected one and sends the request once more. `.refreshed`: the answer to the second request goes back, whatever it is. `.rejected` (the Worker said 400 or 401, or no refresh token is stored): the original 401, so the session ends as it always did. `.unavailable` (offline, timeout, 429, 5xx, a route that is not there, a malformed answer): thrown, never as a 401, so nobody is signed out.
- **A session ends only** when a 401 arrives and there is no refresh token to try, when the Worker rejects the refresh token, or when a request repeated with a fresh token is rejected again. It still ends in one place, `AuthViewModel.handleRejectedAccessToken`, and the reporter is told the token the rejected attempt carried (the new one, after a replay).
- **No refresh at launch and none before expiry.** `restoreSession()` counts a stored refresh token as a live session; the first 401 does the refresh.
- **Sign-out** switches location sharing off, then revokes the refresh token, both inside the same 3 s window (sharing first; the revoke gets what is left), then clears both tokens. A session that ends by rejection or by an Apple revocation clears both tokens and calls nothing.

## Alternatives

- **Renew the JWT with itself** (`POST /v1/auth/renew` takes a still-valid or recently expired access token). No migration, but one token is both key and renewal ticket: a leaked token renews forever, nothing can be revoked, nothing detects reuse, and accepting expired tokens quietly lengthens their life.
- **Run Sign in with Apple again.** It needs the system sheet, so it cannot happen under a request that is already in flight.

## Consequences

- **Deploy order:** migration 022, then the Worker, then a TestFlight build (a push builds nothing). The Worker is compatible with every installed build. Until a viewer signs in on the new build they hold a 30-day token and no refresh token, and behave as before.
- **A rolled-back Worker** keeps the table but has no refresh route: it answers **405**, which the app reads as unavailable. Nobody is signed out; public reads (feed, comments, a public profile) fall back to guest, everything else fails with a service error until the Worker is deployed again.
- **Lost responses.** A refresh whose answer never arrived leaves the phone with a token the Worker already spent. The 60 s leeway and the refresher's own retry (once, about a second later, after a transport failure or a 502, 503 or 504) cover it. Not covered: the app suspended or killed during the call, or no connection for longer than the leeway, followed by a request that gets 401. That looks like reuse and ends the family, so the viewer signs in with Apple once. It needs a loss at the moment of a refresh (at most once a day per device) and then a minute offline. **Upgrade path, additive and not built:** the app sends a random attempt id with each refresh and keeps it with the token until an answer arrives; the Worker stores it on the spent row, so the same token with the same attempt id gets a new successor at any age, while any other reuse still ends the family.
- **No purge of old rows yet.** Every rotation adds a row (at most one a day per signed-in device) and spent, revoked and expired rows are kept until their account goes (`ON DELETE CASCADE`).
- **The startup feed is keyed by the account (`sub`), not by the whole token,** so a refresh does not empty it. Folders keyed by a whole token before this change stay in `Caches`, unused.
- **Public reads read as a guest** when the refresh is unavailable as well as on a 401 (`HTTPClient.dataFallingBackToGuest`), so a refresh route that misbehaves never keeps clips from the viewer.
- **`DubbedAudioCacheClient` and `BackgroundLocationMonitor` get the refresh layer but no reporter** (the earlier decision that their 401s do not end the session stands): without it a 1-day token would make their calls fail daily until another request refreshed. `APITransportComposition` lists the stacks in one place.
- **Checking a real rotation** needs a session and the deployed Worker, so a Debug build has the launch argument `DEBUG_INVALIDATE_ACCESS_TOKEN`, which swaps the stored access token for one the Worker rejects. It is `#if DEBUG` and absent from Release.
- `TokenRefresher` is the sixth actor ([ADR-002](002-ios-concurrency.md)).

## References

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — HTTP API contract ("A 401 ends the session"), Session end, Signing out, Data model
- Design: `docs/superpowers/specs/2026-11-15-token-refresh-design.md`
- `backend/src/routes/authRefresh.ts`, `backend/src/db/refreshTokens.ts`, `backend/sql/022_refresh_tokens.sql`
- `Data/Auth/TokenRefresher.swift`, `Data/API/TokenRefreshingHTTPClient.swift`, `Composition/APITransportComposition.swift`
