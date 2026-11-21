# Account deletion: design

Date: 2026-11-20. Status: **written after the owner chose "ลบทันที" (delete at once, no grace period) and approach A ("A คำขอเดียว": one request that does the steps in order). Read by the builder check on 2026-11-20: its two questions and one wrong premise are settled below and listed in "My calls". Approved by the owner on 2026-11-20 ("อนุมัติ"); nothing is built.**

Size: a project (one Worker route and a small Apple client, three new Worker secrets, a new flow in the app from the Settings row down to the Keychain, docs and one ADR; no migration, no new dependency).

## Intent and why

Marauders lets a person create an account with Sign in with Apple and gives them no way to remove it. App Review Guideline 5.1.1(v) says an app that supports account creation must let the person start the deletion of that account inside the app, and Apple's rule for Sign in with Apple says the app must also revoke the person's Apple tokens when the account is deleted. A read-only audit on 2026-11-20 found three App Store gaps (no account deletion, no report/block, no Privacy/Terms link); the owner chose to design this one first.

What a deletion has to reach, from reading the code and the migrations on 2026-11-20:

- **The `app_users` row** (`id`, `apple_sub`, country, handle, avatar URL, last location and its time, the sharing switch). Five tables reference it with `ON DELETE CASCADE`: `refresh_tokens` (022), `comments.author_user_id` (017), `video_likes.user_id` (018), `user_follows` on both columns (019) and `dubbed_audio_reports.reporter_user_id` (016).
- **The exception: `feed_videos.owner_user_id`** (006) is a plain reference with no cascade, so a user who owns clips cannot be deleted until the clips are. The clips' own children (comments, likes) cascade from `feed_videos`.
- **Files in the R2 bucket** that no row can cascade to: each clip's video (`videos/<uuid>.<ext>`, the key is the tail of `stream_url`; a clip converted to HLS by the ops script `video:hls` is a playlist and segments under `videos/<uuid>/` plus the original upload, see section 4), its dubbed audio and text (`translations/<clip-id>/…`) and the avatar (`avatars/<uuid>.<ext>`; the avatar route already deletes the previous file when an avatar is replaced).
- **Apple.** Today the app sends only the identity token at sign-in and the Worker keeps only `apple_sub`. Nothing in the Worker calls Apple's token or revoke endpoints, and it holds no key to sign a request to them.
- **The phone:** the Keychain session, a pending upload, the personal startup cache of the feed, and everything the signed-in screens hold in memory.

Decisions the owner has made so far: **immediate and permanent** (no 30-day grace period, no undo) and **one request** that does the steps in order (approach A below).

## Goals

1. A signed-in person can delete their account from Settings in the app. No email, web form or support step.
2. After a successful deletion nothing that identifies them stays on our side: the `app_users` row and everything that cascades from it, their clips, and every R2 object that belongs to those rows (videos, dubbed audio and text, the avatar).
3. For an Apple account, Apple is told: the app's access to the person's Apple ID is revoked, so the app disappears from the iPhone's list of apps that use Sign in with Apple.
4. The deletion needs the person to confirm with Apple again (Face ID or passcode). A phone left unlocked, or a stolen access token, is not enough to delete an account.
5. A failure at any step is shown to the person, hides nothing half-way, and can be retried. A retry after the account is already gone succeeds.
6. After success the app is in the state of a sign-out with no data of the deleted account left in the Keychain, the upload queue or the feed cache, and the person sees a clear confirmation.
7. Deletion is a tested path: offline Worker tests with fakes for Apple, R2 and the database; the SQL checked on a real Postgres engine; app unit, UI and accessibility tests; the whole path run once for real before a build that contains it ships.
8. The decision and the how-to are written down (ADR-011, ARCHITECTURE.md, README, the deployment guide).

## Non-goals (each stays a separate decision)

- A grace period, a "deactivated" state, an undo, a confirmation email. (Decided: immediate and permanent.)
- Exporting the person's data before deleting it.
- Report and block, the Privacy Policy and Terms links, the privacy manifest and the App Privacy answers: the other items on the same App Store readiness list, each its own design.
- Background jobs (Cron Triggers, Queues), an outbox table or any migration. That is approach B, kept as the way out if the limits in "Known limits" ever bind.
- Anonymising what the person wrote. Their comments on other people's clips are deleted with the account (cascade), not kept as "[deleted]".
- Finding R2 objects that no row points to (leftovers of old purges or bugs). There is no listing tool for that and it is not about this feature.
- Fixing `DELETE /v1/videos/:id`, which deletes only the key in `stream_url` (see "Found while reviewing"). A separate, small fix.
- Changing sign-in. Nothing new is stored at sign-in.
- A staging backend. There is one backend (production) today (ADR-010, amended 2026-11-20); the design needs no staging, and the first real run is on production, which "Verification" plans for.

## Anti-goals (a failure even if every test passes)

- A success answer while any row or R2 object of the person is still reachable through the app.
- A deletion an access token alone can trigger, for an Apple account (the Apple confirmation is the second factor).
- Data deleted first and Apple told afterwards, leaving a person who is "deleted" but still linked to the app in their Apple ID settings. The order below prevents it.
- The person signed out by an error that is not "your session ended". The app signs the person out on **any** 401 to a request that carried a Bearer token, so this route answers 401 only for a bad Bearer, never for an Apple or code problem.
- A secret in the repo, a log line, a response body, a test fixture or the chat: the `.p8` key, the authorization code and Apple's tokens never appear anywhere.
- Another user's data touched. Every statement is scoped to the user id taken from the verified access token, never from the body.
- A change to the production Worker's name, URL or to the behaviour of any existing route.
- A new layer-checker exception in the app.

## Constraints

From the repo (read 2026-11-20):

- **Worker:** TypeScript on Cloudflare Workers; Neon through `@neondatabase/serverless` (the HTTP driver: each statement is one call, no multi-statement transaction); R2 binding `VIDEOS`; `jose` 5 is already a dependency. No Cron Triggers or Queues exist in the repo. Access tokens are stateless HS256 JWTs checked by `authenticateBearerRequest`; refresh tokens rotate in `refresh_tokens`. Tests are offline, esbuild-bundled suites with fakes for `neon()` and Apple, chained in `npm test`, which CI runs with no secret. `[env.staging]` in `wrangler.toml` must repeat everything it needs (a parity test enforces it). Secrets are set with `wrangler secret put`, never written in the repo. Errors are JSON `{ "error": "…" }` through `errorResponse`.
- **App:** SwiftUI, MVVM with Clean Architecture, a layer checker (`Scripts/check-layers.sh`) with nine deliberate exceptions and no new ones allowed, `@MainActor @Observable` view models, one composition root (`AppDependencyContainer`), API clients over `HTTPClient` and `APIAuthorization`, `Default…` and `UITest…` repository pairs, user-visible strings in `Localizable.xcstrings` with a required Thai translation (`String(localized:)` in Domain and Data), accessibility rules with audit tests, iOS 27.0 deployment target, tests run on the iOS 27.2 simulator.
- **How the app treats a 401.** `RejectedSessionReportingHTTPClient` reports every 401 to a request that carried a Bearer token and the session ends. `TokenRefreshingHTTPClient` first replays such a request once with a refreshed token and the same body, so a request must be safe to replay: the 401 for a bad Bearer comes before any step that spends the Apple code. `RetryingHTTPClient` retries only GET and HEAD, so a DELETE is never retried by the stack.
- **Apple** (found 2026-11-20 by searching Apple's documentation and developer forums; the builder confirms the exact parameter spellings on Apple's current "Generate and validate tokens" and "Revoke tokens" pages before coding): revoking needs one of the person's tokens; with none stored, one is obtained by sending a Sign in with Apple authorization code to `https://appleid.apple.com/auth/token` with the app's client id and a client secret, which is a JWT signed (ES256) with a Sign in with Apple key from the developer account; `https://appleid.apple.com/auth/revoke` then takes the same client id and secret plus the token and a `token_type_hint`. The code is single-use and short-lived (forum posts say five to ten minutes; the app sends it at once). Developers report that revoke answers 200 even for a bogus token, so the Worker **cannot prove** a revocation from the status code; the proof is the manual check in "Verification".
- **Cloudflare limits.** A request can make only so many subrequests (fetches and calls to R2 and the Neon HTTP driver all count) and the number depends on the Cloudflare plan, which the owner has not told me. The design therefore bounds the work per request with one constant instead of assuming a number.

## Approaches considered

### 1. How the Worker gets an Apple token to revoke

- **1a. Ask the person to confirm with Apple again at deletion (chosen).** The app shows the Sign in with Apple sheet, sends the fresh authorization code, the Worker exchanges it for tokens, checks that the Apple account is the signed-in one, and revokes. Costs one Apple sheet (Face ID) at deletion, which doubles as proof that the person holding the phone means it. Nothing changes at sign-in, nothing is stored, and it works for every existing account.
- **1b. Keep Apple's refresh token from sign-in** (the app also sends the code at sign-in, the Worker exchanges it and stores the token per user, revoke needs no prompt). Rejected: a long-lived third-party credential at rest in the database, a migration, a new Apple call inside every sign-in (a failure there would break sign-in), and accounts created before the change have no token, so 1a would be needed anyway.
- **1c. Delete without revoking** and tell people to remove the app in their Apple ID settings. Rejected: Apple asks for revocation, it is the part of the guideline most likely to be checked in review, and the Apple ID would keep listing the app.

### 2. How the deletion runs (the owner chose A)

- **A. One request, ordered steps (chosen).** The Worker does everything inside `DELETE /v1/users/me`, in an order chosen so that any failure can be retried (see the design). No migration, no cron, no new state. Cost: the work per request is bounded (a person with very many clips is asked to delete some first), and a retry after a failure that came after Apple was told needs one more Apple confirmation.
- **B. Mark the account "deleting" and let a background job do the steps** with retries (a Cron Trigger or a Queue). No limit on clips and retries are automatic. Costs: a migration (a state column or an outbox table), a `scheduled` handler and a Cron Trigger (the repo has none), and a way to hold the Apple code across steps (it is single use, so it would have to be stored). Revisit if people start hitting the clip cap or if a grace period is ever wanted.

### 3. When the data goes (the owner chose immediate)

Immediate and permanent, against a 30-day grace period (deactivate now, purge later, restore on sign-in). A grace period needs the background job of 2B and a restore path, and it keeps data the person asked to delete. The owner chose immediate on 2026-11-20.

## The design

### 1. The contract: `DELETE /v1/users/me`

Added next to the existing `GET` and `PATCH` on `/v1/users/me` in `backend/src/index.ts`.

```
DELETE /v1/users/me
Authorization: Bearer <access token>
Content-Type: application/json

{ "authorizationCode": "<code from Sign in with Apple>" }
```

The code is required for an Apple account (a string of 1 to 1,024 characters) and ignored for a `dev:` test user (see section 2, step 6).

| Status | Meaning |
|---|---|
| 204 | The account is deleted. Also the answer when an earlier attempt already finished (the user row is gone). |
| 400 | The body is not a JSON object or `authorizationCode` is not a string of 1 to 1,024 characters; an Apple account sent no code; or Apple did not accept the code (`invalid_grant`). |
| 401 | **Only** a missing, invalid or expired Bearer. Never for anything Apple-related. |
| 403 | The Apple account that confirmed is not the one signed in (`sub` differs). |
| 409 | The person has more clips than one request may delete (`{ "error": …, "limit": N }`). Nothing was touched. |
| 429 | Rate limit (existing helper, scope `account-delete`). |
| 502 | An upstream failed: Apple unreachable or answered 5xx, or R2 failed. Retryable. |
| 503 | Account deletion is not available: an Apple secret is missing, or Apple answered `invalid_client` (our key or ids are wrong). Retryable only after the owner fixes it. |
| 500 | The database statement failed. Retryable. |

Responses carry no code, token or key. The `APPLE_*` values are never echoed. A Worker without this route (before the deploy, or after a rollback) answers 405; the app shows the same "not available" text as for 503.

### 2. The order of the steps, and why

1. **Authenticate** with `authenticateBearerRequest` → 401.
2. **Rate limit** with `enforceDatabaseRateLimit(databaseUrl, { scope: "account-delete", limit: 5, windowSeconds: 3600 }, userId)` → 429. This keeps a loop from hammering Apple's token endpoint.
3. **Read the body**: a JSON object whose `authorizationCode`, when present, is a string of 1 to 1,024 characters → 400. Whether a code is needed is not known until step 4, so it is enforced in step 6.
4. **Load the user** (`id`, `apple_sub`, `avatar_url`) from `app_users`. **No row → 204**, without calling Apple: an earlier attempt finished, and the access token has not expired yet.
5. **Load the clips** (`id`, `stream_url`) with `LIMIT cap + 1`. More than `cap` → **409** before anything external happens. (Steps 4 and 5 may be one joined statement.)
6. **Apple**, skipped when `apple_sub` starts with `dev:` (only `authDev` creates such a value; a real Apple `sub` never looks like it). From here on the work runs to completion even if the client goes away (see "Run to completion" below).
   1. No `authorizationCode` for an Apple account → **400**. Missing `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` or `APPLE_CLIENT_ID` → **503**, before any call to Apple. Production fails closed.
   2. Sign the client secret (ES256, `iss` team id, `sub` client id, `aud` `https://appleid.apple.com`, a short `exp`, header `kid` key id) with `jose`'s `importPKCS8` and `SignJWT`.
   3. `POST https://appleid.apple.com/auth/token` with the client id, the secret, the code and `grant_type=authorization_code`. Apple `invalid_grant` → 400; `invalid_client` → 503; network error or 5xx → 502.
   4. Verify the returned `id_token` with the existing `verifyAppleIdentityToken(idToken, APPLE_CLIENT_ID)` (it checks the signature, issuer and audience and returns the `sub`) and compare that `sub` with `apple_sub`. Different → **403**, and nothing else is done (the stray grant for the other Apple ID is left alone).
   5. `POST https://appleid.apple.com/auth/revoke` with the refresh token. Non-2xx → 502 (`invalid_client` → 503). Nothing has been deleted yet.
7. **R2**, only now: the avatar object (when `avatar_url` maps to a key under `avatars/`) and, for every clip, all of its objects (section 4: its video, or for an HLS clip the playlist, the segments and the original upload) and its dubbed audio (`deleteDubbedAudio(bucket, clipId)`, which lists and deletes the `translations/<clip-id>/` prefix). A clip whose `stream_url` is not in our bucket has nothing to delete. Deleting a key that is already gone is a no-op in R2. Each call is attempted up to three times (a short pause between) before the step fails; a failure → 502, and **no row has been touched**.
8. **The database**, one statement (section 3), attempted up to three times. Failure → 500.
9. **204.**

Why this order: Apple (step 6) is the external call most likely to fail and it destroys nothing; R2 (step 7) is next because it is idempotent and the rows still say what to retry; the rows go last (step 8) because they are the index a retry works from. Doing the rows first would leave R2 objects nobody can find.

**The invariant this order buys:** the user row is deleted only after Apple has been told, so a missing row always means a revoked grant, and an Apple outage can never leave a person "deleted" but still linked. The price is a failure after the revoke (Known limit 3), which the next paragraph makes rare.

**Run to completion.** From step 6 on, the work runs under `ctx.waitUntil` and the response still waits for it, so a client that goes away mid-request (the app killed, the network lost) cannot cut a deletion in half. `fetch` takes only `request` and `env` today and gains the `ctx` parameter for this. The builder confirms on Cloudflare's current documentation how long the runtime keeps such work alive after a disconnect; a deletion should take a few seconds.

What each failure leaves behind:

| Fails at | Left behind | A retry |
|---|---|---|
| Step 6 (any Apple step) | Nothing deleted. | A new confirmation with Apple. |
| Step 7 (R2), after three attempts | Apple revoked; some objects gone; every row intact. | A new confirmation: the person authorises the app again and the Worker revokes again. The app may have signed the person out meanwhile (Known limit 3). |
| Step 8 (database), after three attempts | Apple revoked, objects gone, rows intact: the person's clips exist but do not play. | The same. |
| After step 8, response lost | Everything gone. | The same request answers 204 (step 4) while the access token lives; after that the refresh fails and the person is signed out by the existing 401 handling. |

### 3. The SQL

Reads (one joined statement, or two): the user, and the clips, limited to `cap + 1` rows. The deletion is one statement:

```sql
WITH deleted_clips AS (
  DELETE FROM feed_videos WHERE owner_user_id = $1 RETURNING id
)
DELETE FROM app_users WHERE id = $1;
```

`feed_videos.owner_user_id` has no `ON DELETE` clause, so its foreign key is `NO ACTION`, which Postgres checks at the end of the statement, when the clips are already gone; a data-modifying CTE always runs to completion even though the main query does not read it. Everything else cascades from the two deletes (comments and likes on the clips, and the person's own comments, likes, follows, reports and refresh tokens). **This has to be proven on a real Postgres engine** (PGlite, see "Verification"). If it does not hold, the fallback is two statements, clips first and the user second; that is also safe, because a retry finds the user row and no clips and finishes (step 4 then step 8).

The statement deletes by `owner_user_id`, not by the ids read in step 5, so a clip added from another device in between does not make the user delete fail.

### 4. The R2 objects of a clip

A clip is not always one object. Plain uploads are `videos/<uuid>.<ext>`, but `npm run video:hls` (an ops script; "mixed HLS and MP4 in the feed" is by design in ARCHITECTURE.md) converts a clip to `videos/<uuid>/master.m3u8` plus `videos/<uuid>/segNNN.ts` under the **same uuid**, points `stream_url` at the playlist and never deletes the original `videos/<uuid>.<ext>`. Media is served without authentication (`GET /v1/media/{key}`), so a segment or an original left behind stays public. The rule for a deletion: take the uuid from the key in `stream_url` (never from the clip id) and delete **every object whose key starts with `videos/<uuid>`** (a uuid has a fixed length, so that prefix cannot reach another clip), plus the dubbed audio prefix. Only a key of the exact form `videos/<36-character lowercase uuid>/…` is deleted by prefix; any other key (`videos/demo.mp4`, an upper-case uuid) is deleted exactly, and a key containing `..` or a backslash is skipped, so an odd `stream_url` can never widen the delete. For a plain clip the key is known and can be deleted without listing; only an HLS clip (a key of the form `videos/<uuid>/…`) needs the listing. The new module `backend/src/storage/clipObjects.ts` holds this rule, so the route that deletes a single clip can adopt it later.

The two existing helpers that read a key out of a URL, `objectKeyFromStreamUrl` in `deleteVideo.ts` and `objectKeyFromUrl` in `avatar.ts`, are private. Each gets an `export` keyword in place and the new module imports them: no third copy, nothing moved, no change of behaviour. Neither route has a test today, so this feature does not refactor them. `deleteDubbedAudio` is already exported. `DELETE /v1/videos/:id` itself is not touched; see "Found while reviewing".

### 5. Apple client and secrets

- New `backend/src/auth/appleClient.ts`: `createAppleClientSecret`, `exchangeAuthorizationCode`, `revokeAppleToken`. Each takes the `fetch` it uses as a parameter, so tests pass a fake. No new dependency (`jose` has `SignJWT` and `importPKCS8`).
- Three new Worker secrets, per environment that needs deletion (today production only): `APPLE_TEAM_ID` (10 characters), `APPLE_KEY_ID` (10 characters), `APPLE_PRIVATE_KEY` (the text of the `.p8` file; the Worker accepts real newlines or `\n` escapes). `APPLE_CLIENT_ID` (the bundle id) already exists and is the client id.
- The owner creates the key in the Apple Developer portal (Certificates, Identifiers & Profiles → Keys → add a key with Sign in with Apple, linked to the app's App ID) and downloads the `.p8`, which Apple lets them do **once**. The key id is on the key's page, the team id on the membership page. The value is set with `wrangler secret put APPLE_PRIVATE_KEY < AuthKey_XXXX.p8` from the owner's terminal, or by me with their yes, reading the file on stdin: the value never goes through chat or any log.
- `Env` in `index.ts` gets the three optional fields; `wrangler.toml`'s header comment lists them; `backend/.dev.vars.example` lists them (empty) and its test (`noHardcodedTargets.test.mjs`, "exactly the four names") becomes seven. `[env.staging]` needs no change because secrets are not in the file.

### 6. The clip cap

The cost of a deletion is about two subrequests per plain clip (the dub prefix listing and, when dubs exist, the delete; the videos can go in bulk deletes of up to 1,000 keys) and about four per HLS clip (its own listing and delete as well), plus a fixed handful (rate limit, user, clips, the identity-token key fetch, Apple's token and revoke calls, the avatar, the final statement). One constant, `MAX_CLIPS_PER_DELETION`, bounds it. The builder sets it from Cloudflare's current limit for the Worker's plan with a margin, after asking the owner which plan it is on, and does not trust the arithmetic in this paragraph. A person over the cap gets 409 with the limit and the app tells them to delete some clips from Profile first. On a small plan the cap may be only a few dozen clips.

### 7. The app: flow and screens

Where: Settings gets an **Account** section, shown only when signed in, with a destructive row **Delete Account** (and the footer "Permanently deletes your account and everything in it."). Sign Out stays where it is, on Profile.

The row opens a sheet that `ContentView` presents the way it presents the sign-in sheet (its own `@State`, outside Settings), because the Settings row disappears the moment the session ends and the confirmation must outlive it.

```
┌─────────────────────────────────────────┐
│ Delete Account                  Cancel  │
│                                         │
│ This permanently deletes your Marauders │
│ account and everything in it:           │
│   • your clips                          │
│   • your comments, likes and follows    │
│   • your profile and photo              │
│   • your shared location                │
│ This cannot be undone.                  │
│                                         │
│ To confirm, continue with Apple. Your   │
│ account is deleted as soon as Apple     │
│ confirms it's you.                      │
│                                         │
│   [  Continue with Apple  ]  (system)   │
└─────────────────────────────────────────┘
```

States (`AccountDeletionViewModel.phase`):

- **idle**: the sheet above.
- **deleting**: the button is replaced by a progress indicator and "Deleting your account…"; Cancel is disabled and the sheet cannot be swiped away.
- **failed(message)**: the same sheet with the message in red above the button (the person can try again).
- **deleted**: "Your account was deleted" and "Everything in it was removed from Marauders.", one Done button. By then the app has already signed out behind the sheet.

The button is SwiftUI's `SignInWithAppleButton(.continue)` with no requested scopes (the same control the sign-in gate uses); its completion gives an `ASAuthorizationAppleIDCredential` whose `authorizationCode` (Data) becomes the string the Worker wants. A cancelled Apple sheet returns to idle silently, like the sign-in does.

Two test-only variants, in the same way the sign-in gate does them (`#if DEBUG`, with `AppRuntimeConfiguration.isUITesting` or `DevLogin.isDevUserID`): in a UI test the sheet shows a plain button instead of the Apple one, because the Apple sheet cannot be driven; in a Debug build signed in as a `dev:` test user it shows a plain "Delete test user" button, which sends no code.

Errors the person can see (English; the Thai texts are the builder's, flagged for the owner's review like the rest of the Thai table):

- "We couldn't finish deleting your account. Please try again." (5xx, network, timeout)
- "Apple couldn't confirm it's you. Please try again." (400, or no code from Apple)
- "That isn't the Apple ID you signed in with." (403)
- "You have more than N clips. Delete some from your Profile first, then try again." (409; the number from the response)
- "Too many attempts. Please try again later." (429)
- "Account deletion isn't available right now. Please try again later." (503, and 405 from a Worker that does not have the route yet)
- "Your session has ended. Please sign in again." (401; this string already exists)

### 8. The app: layers and files

Presentation never imports Data, the layer checker stays at its nine exceptions, and the pieces follow the existing pairs:

- **Domain:** `Repositories/AccountDeletionRepository.swift` (`deleteAccount(authorizationCode: String?) async throws`), `Entities/AccountDeletionError.swift` (a `LocalizedError` with `String(localized:)` texts, like `LocationSharingError`), `UseCases/DeleteAccountUseCase.swift`.
- **Data:** `API/AccountDeletionAPIClient.swift` (a `DELETE` to the existing `userProfileURL()`, JSON body, Bearer through `APIAuthorization`, a 60-second `timeoutInterval`, the status table above mapped to `AccountDeletionError`), `Repositories/DefaultAccountDeletionRepository.swift`, `Repositories/UITestAccountDeletionRepository.swift` (succeeds after a short delay; a launch argument makes it fail, for the failure UI test). This client lives in the app, not in `MaraudersAuth`: that package sends no Bearer.
- **Presentation:** `Settings/AccountDeletionViewModel.swift` (`@MainActor @Observable`, a double tap while deleting does nothing), `Settings/DeleteAccountSheet.swift`, the new section in `SettingsView` (a closure `onDeleteAccount`, like `onSignIn` elsewhere), and `ContentView` (a new `accountDeletionViewModel` parameter, `@State showingDeleteAccount`, the sheet; its `#Preview` and `Presentation/Splash/AppRootView.swift`, the one place that builds `ContentView`, change with it).
- **Composition:** `AppDependencyContainer` resolves the repository the way it does for likes and follows (an injected one, else the UI-test one when `isUITesting` and the session is not a rejected-session test, else the real one over `transport` and `apiAuthorization`), builds the use case and the view model, and sets `accountDeletionViewModel.onAccountDeleted` to `authViewModel.finishAccountDeletion()`, the way `profileViewModel.onClipDeleted` is wired.

### 9. What happens on the phone after success

`AuthViewModel.finishAccountDeletion()` is the local half of a sign-out and nothing else: it makes **no Worker call** (the rows are gone; the location-sharing and refresh-token revoke calls would only fail). It stops a sign-in-as-test-user retry, drops the pending upload through the existing `discardUploadOnSignOut` hook (same 3-second bound), clears the Keychain session and both tokens (`clearStoredSession()`), sets `isSignedIn = false` and clears `errorMessage`.

Setting `isSignedIn = false` already makes `ContentView` reset the profile, feed, likes, follows and friend locations, and `FriendLocationsViewModel.reset(signedOut: true)` switches the background location monitor off. New for this feature: the personal startup cache of the feed (`Caches/PersonalFeedStartup-v2`, which holds copies of the feed's clips, the person's own included) is removed; the whole folder goes, because it is only a cache that refills and its sub-folders are hashes. The builder adds the method where the cache's isolation allows it and makes sure it cannot race a write.

### 10. Localization and accessibility

- Every new string goes in `Localizable.xcstrings` with Thai. The system button's text is the system's.
- Accessibility identifiers: `settings.deleteAccount`, `deleteAccount.sheet`, `deleteAccount.cancel`, `deleteAccount.appleButton`, `deleteAccount.progress`, `deleteAccount.error`, `deleteAccount.done`. The row has the destructive role; the sheet follows the accessibility rules in ARCHITECTURE.md and gets its own audit test next to `testSettingsPassesTheStableAudits`.

### 11. Documentation

ADR-011 "Account deletion" (the decisions above and the alternatives) with its line in `docs/adr/README.md`; ARCHITECTURE.md (the route table row and a short section); the README and `deployment/README.md` (the three secrets, how the key is made, the rollout order); `backend/wrangler.toml` and `.dev.vars.example`.

### 12. Rollout (each step is the owner's yes; nothing is deployed, migrated or built before it)

1. The owner creates the Sign in with Apple key and the three secrets are set on production.
2. The Worker is deployed with the guarded script (tests first, then the confirmation phrase). **No migration.**
3. **Check A, no Apple:** on the Simulator, as a `dev:` test user with one or two test clips, delete the account against production. This proves the R2 and database path on real infrastructure with test data only. If production holds HLS-converted clips (a count of `feed_videos` rows whose `stream_url` ends in `.m3u8` answers that), one converted test clip joins this check; otherwise the offline fixture is the proof for them.
4. **Check B, real Apple:** on a phone, with an Apple account the owner is willing to lose (a spare Apple ID, or their own account; signing in again creates a fresh empty account), delete the account, then confirm in the iPhone's Apple ID settings that the app no longer appears under Sign in with Apple. App Review will do exactly this with its own Apple ID.
5. A TestFlight build with the feature (the owner starts Jenkins), only after checks A and B.

Rollback: `wrangler rollback` to the previous version (the route is a 405 again and the app shows "unavailable"). There is no migration to undo and the secrets can stay.

## Verification

- **Worker, offline** (`backend/test/accountDeletion.test.ts`, added to the `npm test` chain so CI runs it): 401 without a Bearer, 429, 400 for a bad body, 204 when the user row is gone (and no call to Apple), 409 over the cap (and no call to anything), 403 on a `sub` mismatch (nothing deleted), each Apple failure (exchange, `invalid_grant`, `invalid_client`, revoke, network) mapped as the table says with nothing deleted, 503 when a secret is missing, the `dev:` path with no Apple call, an R2 failure leaving the database untouched and a second request with a new code then finishing the job, a plain clip and an HLS clip (playlist, segments, original) both fully removed, the success order recorded (exchange, revoke, R2 deletes, the one statement), the steps running under a fake `waitUntil`, and that no response or fixture contains the code, a token or the key. The two existing routes change only by an `export` keyword (neither has a test today); typecheck and the whole `npm test` stay green.
- **Real Postgres:** a one-off PGlite run in a scratch directory (no new dependency, evidence recorded in the plan): load the migrations, insert a user with clips, comments, likes, follows, reports and refresh tokens, plus a second user who comments on and likes the first one's clips, and who is followed by the first; run the deletion statement; assert the first user's rows and everything cascading are gone and the second user's own rows are intact; assert that one statement passes the foreign key check, or that the two-statement fallback is needed.
- **Early proofs the builder does first**, because each can change the design: that a `DELETE` with a JSON body survives URLSession, Cloudflare and the Worker (a unit test of the API client plus one real request; fallback: `POST /v1/users/me/delete`); the CTE result above; Apple's current parameter names; the plan's subrequest limit.
- **App, on the iOS 27.2 simulator from a scratch copy:** unit tests for the use case, the view model (every phase, the error mapping, double tap, a cancelled Apple sheet, and a failed attempt followed by a successful one from the same sheet), the API client (request shape and every status), `finishAccountDeletion` (session cleared, upload discarded, no Worker call); UI tests with the double (the row shows only when signed in; the sheet opens and Cancel closes it; success ends signed out; failure shows the message and keeps the session); the accessibility audit of the sheet; the catalog completeness test; `check-layers.sh --strict` clean.
- **Real runs:** checks A and B in "Rollout". The tests prove the code; only check B proves Apple, because Apple's revoke answers 200 whatever it is given.

## Known limits (written down so none is a surprise)

1. **A cap on clips per request**, set from the plan's limit. A person over it has to delete clips first. Approach B removes the cap.
2. **A retry after a failure that came after Apple was told** needs one more Apple confirmation, because no state is kept between attempts.
3. **A failure after Apple was told** (R2 or the database failing three times in a row after the revoke). The account still exists and some or all of its files are gone, so clips do not play and the last location may still show. The person can retry at once from the sheet. If they leave it, the next time the app asks Apple about the saved session (a relaunch, or opening Profile, Map or Upload, each of which runs `restoreSession`) Apple reports the credential as revoked and the app signs the person out locally, as it does for any revoked credential. Signing in again with the same Apple ID reaches the same account (the same `apple_sub`), and Delete Account works again. The app cannot tell this failure from an Apple-side one (both are 502), and `restoreSession` is not changed for it: the waits, the retries and `waitUntil` above are what make it rare. ARCHITECTURE.md gets one line saying so.
4. **A clip uploaded from another device during the few seconds of a deletion** can leave an R2 object with no row.
5. **Other devices of the person** stay signed in until their next like, follow, comment or friend-locations request: those routes answer 401 "account not found" for a user row that is gone, and the existing 401 handling signs the device out (at the latest when the access token expires and the refresh fails, because the refresh-token rows are gone). A token minted before the deletion cannot write anything in the meantime: every write needs the user row. Signing in again with the same Apple ID creates a new, empty account.
6. **Dubbed audio the person uploaded for other people's clips stays**, labelled with an id that no longer points to anyone (see "My calls").
7. **Viewers who already loaded one of the person's clips** keep playing their cached copy until it is evicted.
8. **Backups.** Neon keeps history for a restore window set by its plan, and Cloudflare gives no promise about internal copies of deleted R2 objects. The privacy policy (a separate design) has to say that deletion from backups follows the providers' schedules. Not checked for the owner's plans.
9. **A revoke that Apple answers 200 to without doing it** cannot be seen from the Worker.

## Found while reviewing (not part of this feature)

`DELETE /v1/videos/:id` deletes only the key in `stream_url`. For a clip converted with `npm run video:hls` that key is the playlist: the segments and the original upload stay in the bucket, and stay public through `GET /v1/media/{key}`. Whether production has any such clip is not known (the count in "Rollout" answers it). The rule in section 4 would fix that route in a few lines, with tests; it is a separate, small decision for the owner.

## What is left to the builder

File and test names beyond those given; whether the two reads are one statement; the exact copy and its Thai; the clip cap and the rate-limit numbers; the timeouts and the pause between the three attempts; the layout of the sheet within the rules; where the startup-cache removal lives; how the Apple client is faked in tests (the existing fake Apple module for the identity token shows the pattern).

## Needed from the owner during the build (not design questions)

- Creating the Sign in with Apple key in the developer portal and the three secrets (I guide each step; the values never go through chat).
- Which Cloudflare plan the Worker is on (it sets the clip cap).
- An Apple account they are willing to lose for check B.
- Optionally, whether production has HLS-converted clips (the count in "Rollout"; I can run it read-only with their yes).
- Their yes at each production step in "Rollout".

## My calls (for the owner to check while reading)

1. **Strict revoke, in the order Apple → R2 → rows** (the one call most worth your attention). The user row is deleted only after Apple was told, so a missing row always means a revoked grant, and an Apple outage blocks the deletion (the person retries later) instead of leaving them deleted but still linked. The price, found by the builder check: if R2 or the database then fails three times in a row, Apple has already marked the credential revoked, and the app may sign the person out on its own before they retry (Known limit 3). I keep the order and shrink that window (retries, `waitUntil`) rather than change `restoreSession`, persist a "deletion pending" marker, or reverse the order. The alternative is to revoke last and tolerate a revoke failure: no sign-out problem, but an Apple outage would leave a deleted person still linked in their Apple ID settings, and a crash between the last two steps would leave that unnoticed.
2. **The Apple sheet is required** at deletion (the confirmation and the source of the code).
3. **Comments the person wrote on other people's clips are deleted** with the account, not anonymised (the cascade does it for free).
4. **Dubbed audio the person uploaded for other people's clips stays.** It is a machine translation shared by everyone who listens in that language, the id on it becomes meaningless, and deleting it would degrade other viewers' experience.
5. **A cap on clips per request**, with a clear message; its value waits for the Cloudflare plan.
6. **The Delete Account row is in Settings**, not next to Sign Out on Profile.
7. **`dev:` test users delete without Apple**, with a Debug-only plain button; it gives a safe way to run check A.
8. **All three Apple values are Worker secrets**, although the Team ID and the Key ID are identifiers, not secrets: one mechanism is simpler than two.
9. **`DELETE /v1/users/me` with a JSON body**, not a separate POST route (with the fallback above if the body does not survive the stack).
10. **Five attempts per hour per user, a 60-second client timeout.**
11. **The SQL proof is a one-off PGlite run**, not a committed test or a new dependency.
12. **The whole startup-cache folder is removed locally**, not only the deleted account's sub-folder.
13. **The "deleted" confirmation lives in the sheet**, which `ContentView` keeps alive after the sign-out.
14. **HLS clips are covered** by deleting every object under `videos/<uuid>`, whether or not production has any (the offline tests carry a fixture). `DELETE /v1/videos/:id` is left alone and reported under "Found while reviewing".
15. **The two key helpers are exported in place, not moved**, because neither route has a test to protect a refactor.
16. **The steps from Apple onward run under `ctx.waitUntil`, and each R2 call and the final statement is attempted up to three times**, so a dropped connection or a hiccup does not cut a deletion in half.
17. **503 and 405 get their own message** ("not available right now"), apart from the generic "try again".
18. **Only a clean `videos/<uuid>/…` key is deleted by prefix** (added while writing the plan, after your approval): any other key is deleted exactly or skipped, so a `stream_url` that is not what the upload route writes can never turn the prefix into a wider delete.
