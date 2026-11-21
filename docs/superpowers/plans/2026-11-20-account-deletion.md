# Account Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in person can delete their Marauders account from Settings: the Worker revokes their Sign in with Apple grant, removes their R2 files and their rows, and the app ends signed out with nothing of the account left on the phone.

**Architecture:** One Worker route, `DELETE /v1/users/me`, runs the steps in a fixed order (Apple, then R2, then one SQL statement) under `ctx.waitUntil`. A small Apple client signs the client secret and calls Apple's token and revoke endpoints. The app re-authenticates with Sign in with Apple, sends the authorization code, and on 204 ends the session locally and clears the personal feed cache. No migration, no new dependency.

**Tech Stack:** Cloudflare Worker (TypeScript, `jose`, Neon HTTP driver, R2), node:test with esbuild runners, PGlite (a scratch proof only); iOS SwiftUI, MVVM + Clean Architecture, Swift Testing, XCUITest.

**Spec:** `docs/superpowers/specs/2026-11-20-account-deletion-design.md` (approved by the owner on 2026-11-20). Read it first; this plan cites its sections as §n and does not repeat them.

## Global Constraints

- **Scope:** no migration, no Worker dependency beyond `jose`, no new Swift package, no change to the behaviour of any existing route (the two key helpers only gain `export`), no new layer-checker exception (`Marauders-ios/Scripts/check-layers.sh --strict` stays clean at its nine entries).
- **Route (§1):** `DELETE /v1/users/me`, JSON body `{ "authorizationCode": <string, 1 to 1,024 characters> }`, required for an Apple account and ignored for a `dev:` user. Statuses exactly: 204, 400, 401 (a missing, invalid or expired Bearer **only**), 403, 409 (`{ "error": …, "limit": N }`), 429, 500, 502, 503. A response never echoes a code, a token or a key; error messages are short lowercase English like the other routes and never carry upstream text.
- **Order (§2):** authenticate → rate limit → body (400) → user (no row ⇒ 204, no Apple call) → clips `LIMIT cap + 1` (more than `cap` ⇒ 409) → Apple (skipped when `apple_sub` starts with `dev:`) → R2 → one SQL statement → 204. From Apple onward the work runs under `ctx.waitUntil` while the response still awaits it. The user row is deleted only after Apple was told.
- **Rate limit:** `{ scope: "account-delete", limit: 5, windowSeconds: 3600 }` per user id, through `enforceDatabaseRateLimit`.
- **Apple (§2 step 6, §5):** `POST https://appleid.apple.com/auth/token` (`grant_type=authorization_code`) and `POST https://appleid.apple.com/auth/revoke` (`token_type_hint=refresh_token`). Client secret: ES256 JWT, header `kid` = key id, `iss` = team id, `sub` = client id (`APPLE_CLIENT_ID`), `aud` = `https://appleid.apple.com`, `exp` 300 s after `iat`. `invalid_grant` ⇒ 400, `invalid_client` ⇒ 503, network error or 5xx ⇒ 502, a missing `APPLE_*` value ⇒ 503 before any call, a different `sub` ⇒ 403.
- **Secrets:** `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (the `.p8` text; real newlines or `\n` escapes). Their values never appear in the repo, a log line, a response, a fixture, a commit message or the chat; tests generate keys at run time.
- **Cap:** `MAX_CLIPS_PER_DELETION = 15` until the owner says which Cloudflare plan the Worker is on (Rollout R1); tests import the constant and never write 15.
- **R2 (§4):** the uuid comes from the key in `stream_url`, never from the clip id. Only a key of the exact form `videos/<36-character lowercase uuid>/…` is deleted by prefix (`videos/<uuid>`); every other key is deleted exactly; a key with `..` or a backslash is skipped. Each R2 call and the final statement are attempted 3 times (150 ms apart) before the step fails (502 and 500).
- **SQL (§3):** one statement, `WITH deleted_clips AS (DELETE FROM feed_videos WHERE owner_user_id = $1 RETURNING id) DELETE FROM app_users WHERE id = $1;`, by `owner_user_id`, not by the ids read earlier. Task 3 proves it on Postgres; the two-statement fallback (clips first) applies if the proof fails.
- **App (§7 to §10):** Settings "Account" section only when signed in; the sheet is presented from `ContentView`; `SignInWithAppleButton(.continue)` with no scopes; request timeout 60 s; body `{"authorizationCode":"…"}`, or `{}` without a code; `AuthViewModel.finishAccountDeletion()` makes no Worker call; the whole `PersonalFeedStartup-v2` folder is removed; accessibility identifiers `settings.deleteAccount`, `deleteAccount.sheet`, `deleteAccount.cancel`, `deleteAccount.appleButton`, `deleteAccount.progress`, `deleteAccount.error`, `deleteAccount.done`; every new user-visible string is in `Localizable.xcstrings` with a Thai translation (developer-only Debug texts use `Text(verbatim:)`); iOS 27.0 deployment target.
- **Process:** work in a worktree branch `claude/account-deletion`, one commit per task, short imperative messages like the repo's; never stage or touch `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` (the owner's own uncommitted edit on main); the spec and this plan are untracked files of the main checkout (`/Users/tiscomacnb2486/Desktop/Marauders/docs/superpowers/`), so a worktree does not contain them: read them there by absolute path, and do not commit them unless the owner says so; no push, merge, deploy, migration, secret or production call without the owner's explicit yes.
- **Test commands.** Worker: `cd backend && npm run test:account-deletion` (this feature) and `npm test` (everything). App, on the iOS 27.2 simulator only:
  ```bash
  xcodebuild test -project Marauders-ios/Marauders.xcodeproj -scheme "Marauders Staging" -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' -derivedDataPath <scratchpad>/DerivedData-sim -clonedSourcePackagesDirPath <scratchpad>/SourcePackages -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/<Suite>
  ```
  One `-only-testing:` per suite, each written out. A run counts only when it prints `Test run with N tests` with the N you expect (a filter that matches nothing reports success with 0 tests). Baseline before this work: unit 1347 tests in 134 suites; UI 79 tests with one known simulator-only red, `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn`.

## Review Focus

Failure modes the spec implies and the person using the app is most likely to meet, most likely first. Each has its test in the task named.

1. **An account with no clips and no avatar** (a new account, like the one an App Review tester makes): the deletion succeeds with no R2 call and one statement. Task 4.
2. **The same account deleted twice** (a retry after a lost 204, or two requests racing): the second answers 204 and never calls Apple, R2 or the delete statement. Task 4.
3. **A `stream_url` whose key is not a clean `videos/<uuid>` shape** (`videos/demo.mp4`, a `..`, a backslash, another host, an upper-case uuid): never deleted by prefix, never reaches a neighbour's files. Task 2.
4. **Apple that answers 200 without an `id_token` or a `refresh_token`, or with something that is not JSON:** answer 502, delete nothing. The same for a code that is empty, a number, `null` or 1,025 characters: 400 before anything external. Tasks 1 and 4.
5. **Sign in with Apple that returns no `authorizationCode`** (or bytes that are not UTF-8), and a double tap on the button: the sheet shows "Apple couldn't confirm it's you", sends no request, and never sends two. Task 8.

---

## Task 1: The Apple client, and the runner for this feature's Worker tests

**Files:**
- Create: `backend/src/auth/appleClient.ts`
- Create: `backend/scripts/test-account-deletion.mjs`
- Create: `backend/test/accountDeletionApple.test.ts`
- Modify: `backend/package.json` (script `test:account-deletion`, appended to the `test` chain after `test:upload-idempotency`)

**Interfaces:**
- Produces (`appleClient.ts`):
  ```ts
  export type AppleCredentials = { teamId: string; keyId: string; privateKeyPem: string; clientId: string };
  export type AppleFailure = "invalid_grant" | "invalid_client" | "unavailable";
  export class AppleClientError extends Error { readonly kind: AppleFailure } // message is the kind, never a body, code or token
  export function appleCredentialsFromEnv(env: { APPLE_TEAM_ID?: string; APPLE_KEY_ID?: string; APPLE_PRIVATE_KEY?: string; APPLE_CLIENT_ID?: string }): AppleCredentials | null;
  export async function createAppleClientSecret(credentials: AppleCredentials, now?: Date): Promise<string>;
  export async function exchangeAuthorizationCode(credentials: AppleCredentials, code: string, fetchImpl?: typeof fetch): Promise<{ idToken: string; refreshToken: string }>;
  export async function revokeAppleToken(credentials: AppleCredentials, refreshToken: string, fetchImpl?: typeof fetch): Promise<void>;
  ```
- Runner: bundles every `test/accountDeletion*.test.ts` (matched by name, so later tasks add no list entry) with esbuild into a temp folder and runs `node --test` over them; swaps `@neondatabase/serverless` for `test/fakes/neon.ts` and `src/auth/appleIdentityToken` for `test/fakes/appleIdentityToken.ts` exactly as `scripts/test-auth-refresh.mjs` does, and bundles several entry points to an `outdir` as `scripts/test-comments.mjs` does.

- [ ] **Step 1: Confirm Apple's current parameter names.** Read Apple's "Generate and validate tokens" and "Revoke tokens" pages (the `web-fetch` agent can read them). If a parameter, endpoint or error code differs from Global Constraints, Apple wins: put the confirmed list, with the two page URLs, in a header comment of `appleClient.ts` and tell the owner what differed.
- [ ] **Step 2: Write the failing tests** in `accountDeletionApple.test.ts`. Keys come from `generateKeyPair("ES256", { extractable: true })` and `exportPKCS8`; Apple is a fake `fetch` that records its request.
  - `appleCredentialsFromEnv`: all four values ⇒ the credentials; each of the four missing or `""` ⇒ `null`.
  - `createAppleClientSecret`: with a fixed `now`, `jwtVerify(token, publicKey, { issuer: TEAM, subject: CLIENT, audience: "https://appleid.apple.com" })` passes; header `alg` is `ES256` and `kid` is the key id; `exp - iat === 300`; a key with real newlines and the same key with `\n` escapes both sign a verifiable token; a malformed PEM throws `AppleClientError` with `kind === "invalid_client"`.
  - `exchangeAuthorizationCode`: the request is a POST to `https://appleid.apple.com/auth/token` with `content-type: application/x-www-form-urlencoded` and the fields `client_id`, `client_secret` (a JWT), `code`, `grant_type=authorization_code`; a 200 with `id_token` and `refresh_token` returns `{ idToken, refreshToken }`; a 200 without `refresh_token`, a 200 without `id_token`, and a 200 whose body is not JSON each throw kind `unavailable`; 400 `{"error":"invalid_grant"}` ⇒ `invalid_grant`; 400 and 401 `{"error":"invalid_client"}` ⇒ `invalid_client`; 400 `{"error":"invalid_request"}`, 500 and a rejecting `fetch` ⇒ `unavailable`.
  - `revokeAppleToken`: POST to `https://appleid.apple.com/auth/revoke` with `client_id`, `client_secret`, `token`, `token_type_hint=refresh_token`; 200 resolves; 400 `invalid_client` ⇒ `invalid_client`; 500 and a rejecting `fetch` ⇒ `unavailable`.
  - Every thrown `AppleClientError` has `message === kind`: it contains neither the code, the refresh token, the key nor the response body.
- [ ] **Step 3: Create the runner and the `package.json` script;** run `cd backend && npm run test:account-deletion`. Expected: FAIL (the `appleClient` module does not exist).
- [ ] **Step 4: Implement `appleClient.ts`** with `jose` (`importPKCS8`, `SignJWT`); normalise `\n` escapes before importing; map responses and failures as the tests say and as Global Constraints fix.
- [ ] **Step 5: Run** `npm run test:account-deletion` and `npm run typecheck`. Expected: all pass, typecheck silent.
- [ ] **Step 6: Commit** (`backend/src/auth/appleClient.ts`, `backend/scripts/test-account-deletion.mjs`, `backend/test/accountDeletionApple.test.ts`, `backend/package.json`): "Add the Apple client that exchanges a code and revokes a token".

## Task 2: Every R2 object of a clip, and a retry helper

**Files:**
- Create: `backend/src/retry.ts`, `backend/src/storage/clipObjects.ts`, `backend/test/fakes/bucket.ts`, `backend/test/accountDeletionObjects.test.ts`
- Modify: `backend/src/routes/deleteVideo.ts` (add `export` to `objectKeyFromStreamUrl`), `backend/src/routes/avatar.ts` (add `export` to `objectKeyFromUrl`); nothing else in either file.

**Interfaces:**
- Consumes: `objectKeyFromStreamUrl(streamUrl: string): string | null`, `objectKeyFromUrl(url: string | null): string | null` (both exist, now exported).
- Produces:
  ```ts
  // retry.ts: runs `work` up to `attempts` times with `pauseMs` between tries; rethrows the last error
  export async function withAttempts<T>(work: () => Promise<T>, attempts?: number /* 3 */, pauseMs?: number /* 150 */): Promise<T>;
  // clipObjects.ts
  export type ClipObjectPlan = { kind: "exact"; key: string } | { kind: "prefix"; prefix: string } | { kind: "none" };
  export function planClipObjects(streamUrl: string): ClipObjectPlan;
  export async function deleteClipObjects(bucket: R2Bucket, streamUrls: string[]): Promise<void>; // each list and delete call goes through withAttempts
  export async function deleteAvatarObject(bucket: R2Bucket, avatarUrl: string | null): Promise<void>;
  // test/fakes/bucket.ts: only what the code calls
  export class FakeBucket { objects: Map<string, string>; pageSize: number; failNext(op: "list" | "delete", times: number): void; list(o?: { prefix?: string; cursor?: string }): Promise<{ objects: { key: string }[]; truncated: boolean; cursor?: string }>; delete(keys: string | string[]): Promise<void>; calls: Array<{ op: string; arg: unknown }> }
  ```

- [ ] **Step 1: Write the failing tests** in `accountDeletionObjects.test.ts` (`U` is a lowercase uuid, `V` another):
  - `planClipObjects`: `https://api.test/v1/media/videos/U.mp4` ⇒ exact `videos/U.mp4`; `…/videos/U/master.m3u8` ⇒ prefix `videos/U`; `…/videos/demo.mp4` ⇒ exact; a URL without `/v1/media/` ⇒ none; a key containing `..` or a backslash ⇒ none; `…/videos/<UPPER-CASE uuid>/master.m3u8` ⇒ exact, never prefix.
  - Plain clip: the bucket holds `videos/U.mp4` and `videos/V.mp4`; after `deleteClipObjects(bucket, [urlOfU])` only `videos/V.mp4` is left.
  - HLS clip: the bucket holds `videos/U/master.m3u8`, `videos/U/seg000.ts`, `…seg001.ts`, `…seg002.ts`, the original `videos/U.mov`, and a neighbour `videos/V/master.m3u8`; with `pageSize = 2` everything of U is gone and only the neighbour is left.
  - 2,500 exact keys ⇒ `bucket.delete` is called with arrays of at most 1,000 (three calls); no URLs ⇒ no bucket call.
  - `failNext("delete", 2)` still succeeds on the third attempt; `failNext("delete", 3)` rejects.
  - `withAttempts` (with `pauseMs` 0): returns on the first success, calls `work` at most 3 times, rethrows the last error.
  - `deleteAvatarObject`: `…/v1/media/avatars/U.jpg` is deleted; `null`, a URL outside `/v1/media/` and a key outside `avatars/` make no bucket call.
- [ ] **Step 2: Run** `npm run test:account-deletion`. Expected: FAIL (modules missing).
- [ ] **Step 3: Implement** `retry.ts`, `clipObjects.ts` and `FakeBucket`; add the two `export` keywords. Prefix rule: the key matches `^videos/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/` ⇒ prefix `videos/<uuid>`; every other key from the helper ⇒ exact. Exact keys of all clips go out in chunks of 1,000; a prefix is listed page by page and each page deleted before the next is read.
- [ ] **Step 4: Run** `npm run test:account-deletion` and `npm run typecheck`. Expected: pass.
- [ ] **Step 5: Commit** (the files above): "Delete every R2 object a clip has, and retry each call".

## Task 3: The database statements, and the one-off Postgres proof

**Files:**
- Create: `backend/src/db/accountDeletion.ts`, `backend/test/accountDeletionDb.test.ts`
- Scratch, never committed: the PGlite proof in a folder under the session scratchpad

**Interfaces:**
- Produces:
  ```ts
  export type UserForDeletion = { id: string; appleSub: string; avatarUrl: string | null };
  export type ClipForDeletion = { id: string; streamUrl: string };
  export async function getUserForDeletion(databaseUrl: string, userId: string): Promise<UserForDeletion | null>;
  export async function listClipsForDeletion(databaseUrl: string, userId: string, limit: number): Promise<ClipForDeletion[]>;
  export async function deleteUserAndClips(databaseUrl: string, userId: string): Promise<void>;
  ```

- [ ] **Step 1: Write the failing tests** (fake Neon; the SQL text arrives with `?` where a value goes):
  - `getUserForDeletion` runs one statement `FROM app_users` with `?::uuid` and the user id among its values; it maps `{ id, apple_sub, avatar_url }` to `{ id, appleSub, avatarUrl }` and returns `null` for no row.
  - `listClipsForDeletion(url, USER, 16)` runs one statement on `feed_videos` filtered by `owner_user_id = ?::uuid`, passes 16 as a value, and maps `{ id, stream_url }` to `{ id, streamUrl }`.
  - `deleteUserAndClips` runs exactly one statement matching `/WITH deleted_clips AS \(\s*DELETE FROM feed_videos WHERE owner_user_id = \?::uuid RETURNING id\s*\)\s*DELETE FROM app_users WHERE id = \?::uuid/` with the user id as its value(s).
- [ ] **Step 2: Run** `npm run test:account-deletion`. Expected: FAIL. **Step 3: implement** the three functions with the `neon` tagged template like `src/db/users.ts`; run again, expected pass.
- [ ] **Step 4: Prove the statement on a real Postgres engine.** In a scratch folder: `npm init -y` and `npm install --offline --ignore-scripts @electric-sql/pglite@0.5.8` (if the offline cache no longer holds it, tell the owner and ask before a network install; the scratch folder is the only place it goes). Script: `new PGlite({ extensions: { pgcrypto } })` (`import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto"`); run every `backend/sql/*.sql` in name order; insert users A and B; A owns two clips; B owns one; A and B comment on, like and report each other's clips and follow each other; each has two `refresh_tokens`; run the exact statement text of `deleteUserAndClips` for A. Assert: no error (the `NO ACTION` foreign key passes inside one statement); `app_users` holds only B; `feed_videos` holds only B's clip; no row in `comments`, `video_likes`, `user_follows`, `dubbed_audio_reports`, `refresh_tokens` mentions A or A's clips; B's own rows (including B's comments and likes on B's clip and B's refresh tokens) are intact. Also: A with no clips deletes cleanly; a user id that does not exist deletes zero rows without error.
- [ ] **Step 5: Decide from the proof.** One statement passes ⇒ keep it. It fails on the foreign key ⇒ change `deleteUserAndClips` to two statements (clips first, then the user), change its test to expect two statements in that order, re-run the proof on that form, and tell the owner the design's fallback was used.
- [ ] **Step 6: Commit** (the two files): "Add the statements that delete an account and its clips"; say in the message which form passed the proof and on which PGlite and Postgres versions.

## Task 4: The route handler

**Files:**
- Create: `backend/src/routes/deleteAccount.ts`, `backend/test/accountDeletion.test.ts`
- Modify: `backend/src/validation.ts` (add `parseAccountDeletionBody`), `backend/src/index.ts` (only `Env`: add `APPLE_TEAM_ID?: string; APPLE_KEY_ID?: string; APPLE_PRIVATE_KEY?: string` with a doc comment pointing to ADR-011)

**Interfaces:**
- Consumes: Task 1 (`appleCredentialsFromEnv`, `exchangeAuthorizationCode`, `revokeAppleToken`, `AppleClientError`), Task 2 (`withAttempts`, `deleteClipObjects`, `deleteAvatarObject`), Task 3 (the three DB functions), `deleteDubbedAudio(bucket, id)` from `routes/dubbedAudio.ts`, `verifyAppleIdentityToken(idToken, clientId): Promise<string>`, `FeedValidationError`.
- Produces:
  ```ts
  export const MAX_CLIPS_PER_DELETION = 15;
  export async function handleAccountDelete(request: Request, env: Env, ctx: ExecutionContext, userId: string, fetchImpl?: typeof fetch): Promise<Response>;
  // validation.ts: absent ⇒ { authorizationCode: null }; a string of 1 to 1,024 characters ⇒ itself; anything else (null, a number, "", 1,025 characters, a body that is not an object) throws FeedValidationError 400
  export function parseAccountDeletionBody(body: unknown): { authorizationCode: string | null };
  ```

- [ ] **Step 1: Confirm `waitUntil`.** Read Cloudflare's current documentation for `ExecutionContext.waitUntil` and write down how long the runtime keeps that work after the client disconnects. If it is shorter than a few seconds, stop and tell the owner; otherwise keep the one-sentence finding for the comment above the `waitUntil` call and for ADR-011.
- [ ] **Step 2: Write the failing tests** in `accountDeletion.test.ts`, calling `handleAccountDelete(request, env, ctx, USER, fakeFetch)` directly. A `Scene` helper builds the fake-Neon responder (told apart by SQL text: `rate_limit_counters`, `FROM app_users`, `FROM feed_videos`, the CTE), a `FakeBucket` filled from the clips, a fake Apple `fetch`, an `env` (`APPLE_CLIENT_ID: "com.example.test"` and a key from `generateKeyPair`), a `ctx` that records the promises given to `waitUntil`, and an `events: string[]` journal that every collaborator appends to (`apple:token`, `apple:revoke`, `r2:delete`, `db:delete`). The fake `verifyAppleIdentityToken` returns `apple:<token>`, so a user whose `apple_sub` is `apple:alice` confirms with `id_token` `alice`.
  - **Body (RF 4):** a body that is not an object, a code that is a number, `null`, `""` or 1,025 characters ⇒ 400, `events` empty, `queries.length === 0`.
  - **Gone (RF 2):** no user row ⇒ 204, `events` empty, only the user lookup ran.
  - **Cap:** `MAX_CLIPS_PER_DELETION + 1` clips ⇒ 409 with body `{ error, limit: MAX_CLIPS_PER_DELETION }` and `events` empty; exactly `MAX_CLIPS_PER_DELETION` clips ⇒ 204.
  - **Config:** an Apple account without a code ⇒ 400, `events` empty; each of `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, `APPLE_CLIENT_ID` missing ⇒ 503, `events` empty; no `VIDEOS` binding ⇒ 503, `events` empty; no `DATABASE_URL` ⇒ 503 and no query.
  - **Success:** `events` equals `["apple:token", "apple:revoke", "r2:delete" (avatar, dubbed audio and objects of each clip), "db:delete"]` in that order; the exchange carries the code, the revoke carries the `refresh_token` Apple returned, the delete statement's value is `USER`; the answer is 204 with no body.
  - **Apple failures, each with no `r2:` or `db:` event:** `id_token` of another account ⇒ 403 and no `apple:revoke`; exchange `invalid_grant` ⇒ 400; exchange `invalid_client` ⇒ 503; exchange 500 ⇒ 502; a rejecting `fetch` ⇒ 502; exchange 200 without `refresh_token` ⇒ 502 (RF 4); an `id_token` the verifier refuses (`invalid-x`) ⇒ 502; revoke 500 ⇒ 502; revoke `invalid_client` ⇒ 503.
  - **`dev:` user:** `apple_sub` `dev:ui`, no `APPLE_*` set, body `{}` ⇒ 204, no `apple:` event, clips and rows deleted.
  - **R2 failure then retry:** `failNext("delete", 3)` ⇒ 502 with `apple:token`, `apple:revoke` and no `db:delete`; a second call (new code, working bucket) ⇒ 204.
  - **Database:** a first-attempt failure then success ⇒ 204 (two statements recorded); three failures ⇒ 500.
  - **Objects:** a plain clip, an HLS clip (playlist, three segments, original), a neighbour's clip, the avatar and the dubbed audio of both clips ⇒ afterwards the bucket holds only the neighbour's objects. A clip whose `stream_url` is `https://elsewhere.test/v.mp4` makes no bucket call of its own, and one whose key is `videos/demo.mp4` deletes exactly that key and lists no prefix; the rows go in both cases.
  - **Empty account (RF 1):** no clips and no avatar ⇒ 204, no `r2:` event, one delete statement.
  - **Run to completion:** `ctx.waitUntil` received exactly one promise, and that promise resolves to the very `Response` the handler returned.
  - **No leakage:** across a success and each failure above, no response body, `console` line or recorded query value contains the code, the Apple tokens or the private key text.
- [ ] **Step 3: Run** `npm run test:account-deletion`. Expected: FAIL.
- [ ] **Step 4: Implement** `parseAccountDeletionBody`, the `Env` fields and `handleAccountDelete`: §2 steps 3 to 9 in that order, with the statuses of Global Constraints. Read the body with `request.json()` (a parse failure ⇒ 400); the work from the Apple step on is one promise that never rejects, registered with `ctx.waitUntil` and awaited for the response; `deleteClipObjects` and `deleteAvatarObject` already retry inside, so wrap `deleteDubbedAudio(env.VIDEOS, clip.id)` (once per clip) and `deleteUserAndClips` in `withAttempts`; log nothing but a step name, never an error object or a value.
- [ ] **Step 5: Run** `npm run test:account-deletion` and `npm run typecheck`. Expected: pass.
- [ ] **Step 6: Commit** (the four files): "Add the account deletion route".

## Task 5: Serve the route, and list the three secrets

**Files:**
- Modify: `backend/src/index.ts`, `backend/wrangler.toml` (comment lines 5 to 8 only), `backend/.dev.vars.example`, `backend/test/scripts/noHardcodedTargets.test.mjs`
- Create: `backend/test/accountDeletionRoute.test.ts`

**Interfaces:**
- Consumes: `handleAccountDelete` (Task 4).
- Produces: `DELETE /v1/users/me` in the router; `const ACCOUNT_DELETE_RATE_LIMIT = { scope: "account-delete", limit: 5, windowSeconds: 3600 }` next to `UPLOAD_RATE_LIMIT`; `fetch(request: Request, env: Env, ctx: ExecutionContext = NO_CONTEXT)`, where `NO_CONTEXT` is a stub whose `waitUntil` does nothing, so the ten existing test files that call `worker.fetch(request, env)` need no edit.

- [ ] **Step 1: Write the failing tests** in `accountDeletionRoute.test.ts` (through `worker.fetch`, with access tokens signed as in `test/follows.test.ts`):
  - no `Authorization` ⇒ 401 `{"error":"authentication required"}`; a garbage Bearer ⇒ 401; in both, no query ran and no Apple call was made;
  - the fake Neon answers the rate-limit statement with `count: 6` ⇒ 429 with a `retry-after` header and no user lookup; the rate-limit statement's values include `account-delete:<USER>`;
  - a valid token and no user row ⇒ 204 (the router reaches the handler); a valid token and a `dev:` user with no clips and no avatar (env with `VIDEOS: new FakeBucket()`) ⇒ 204, and the recording `ctx` passed to `worker.fetch` received one `waitUntil` promise;
  - `POST /v1/users/me` still answers 405 `method not allowed`; `OPTIONS /v1/users/me` still answers 204 with `DELETE` in `access-control-allow-methods`.
- [ ] **Step 2: Update `noHardcodedTargets.test.mjs`:** the test "the example lists exactly the four names" becomes "…the seven names" and expects, sorted, `APPLE_CLIENT_ID=`, `APPLE_KEY_ID=`, `APPLE_PRIVATE_KEY=`, `APPLE_TEAM_ID=`, `DATABASE_URL=`, `DEV_LOGIN_SECRET=`, `JWT_SIGNING_SECRET=`.
- [ ] **Step 3: Run** `npm run test:account-deletion` and `npm run test:scripts`. Expected: FAIL.
- [ ] **Step 4: Implement:** the router branch goes after the `PATCH /v1/users/me` branch and follows the file's pattern (authenticate ⇒ 401, `enforceDatabaseRateLimit` ⇒ `rateLimitedResponse`, then the handler, all through `withCors`); add the three names to `.dev.vars.example` with one comment line each; extend the secrets comment in `wrangler.toml` with the three `wrangler secret put` lines (the private key as `< AuthKey_XXXXXXXXXX.p8`, never pasted).
- [ ] **Step 5: Run the whole Worker gate:** `cd backend && npm test`. Expected: typecheck clean, every suite green, including the new ones.
- [ ] **Step 6: Commit** (the five files): "Serve DELETE /v1/users/me and list the three Apple secrets".

## Task 6: The app's Domain and Data layers, and removing the personal feed cache

**Files:**
- Create (all under `Marauders-ios/Marauders/`): `Domain/Entities/AccountDeletionError.swift`, `Domain/Repositories/AccountDeletionRepository.swift`, `Domain/Services/FeedStartupCacheClearing.swift`, `Domain/UseCases/DeleteAccountUseCase.swift`, `Data/API/AccountDeletionAPIClient.swift`, `Data/Repositories/DefaultAccountDeletionRepository.swift`, `Data/Repositories/UITestAccountDeletionRepository.swift`
- Modify: `Data/Services/FeedStartupCache.swift`
- Test (under `Marauders-ios/MaraudersTests/`): create `AccountDeletionAPIClientTests.swift`, `DeleteAccountUseCaseTests.swift`; modify `FeedStartupCacheTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum AccountDeletionError: LocalizedError, Equatable {
      case signInRequired            // 401, text "Your session has ended. Please sign in again." (existing key)
      case appleNotConfirmed         // 400, "Apple couldn't confirm it's you. Please try again."
      case wrongAppleAccount         // 403, "That isn't the Apple ID you signed in with."
      case tooManyClips(limit: Int)  // 409, "You have more than \(limit) clips. Delete some from your Profile first, then try again."
      case rateLimited               // 429, "Too many attempts. Please try again later."
      case notAvailable              // 503 and 405, "Account deletion isn't available right now. Please try again later."
      case couldNotFinish            // anything else, "We couldn't finish deleting your account. Please try again."
  }                                  // texts through String(localized:), like LocationSharingError
  protocol AccountDeletionRepository: Sendable { func deleteAccount(authorizationCode: String?) async throws }
  protocol FeedStartupCacheClearing: Sendable { func removeAll() async }
  struct DeleteAccountUseCase: Sendable {
      init(repository: AccountDeletionRepository, feedCache: FeedStartupCacheClearing?)
      func execute(authorizationCode: String?) async throws // the repository first; the cache is cleared only after it succeeds
  }
  struct AccountDeletionAPIClient: Sendable {
      init(client: HTTPClient, authorization: APIAuthorization? = nil)
      init(session: URLSession = .shared, authorization: APIAuthorization? = nil)
      func deleteAccount(authorizationCode: String?) async throws
  }
  struct DefaultAccountDeletionRepository: AccountDeletionRepository { init(apiClient: AccountDeletionAPIClient) }
  final class UITestAccountDeletionRepository: AccountDeletionRepository, @unchecked Sendable {
      init(fails: Bool) // waits about 300 ms, then succeeds, or throws .couldNotFinish when `fails`
  }
  // FeedStartupCache.swift: `actor FeedStartupCache` gains `func removeAll()`; `SessionFeedStartupCache` conforms to FeedStartupCacheClearing
  ```

- [ ] **Step 1: Write the failing tests.**
  - `AccountDeletionAPIClientTests` (mirror `LocationSharingAPIClientTests`; read the body as `UserLocationAPIClientTests.bodyData(from:)` does, through `httpBodyStream`): a code produces `DELETE` to a URL whose path ends `/v1/users/me`, header `Authorization: Bearer test-token`, `Content-Type: application/json`, `timeoutInterval == 60` and a body whose JSON is `{"authorizationCode":"code-123"}`; no code produces body `{}`; 204 and 200 return; 400 ⇒ `.appleNotConfirmed`; 401 ⇒ `.signInRequired`; 403 ⇒ `.wrongAppleAccount`; 405 and 503 ⇒ `.notAvailable`; 409 with `{"error":"x","limit":15}` ⇒ `.tooManyClips(limit: 15)`; 409 with an unreadable body, 500 and 502 ⇒ `.couldNotFinish`; 429 ⇒ `.rateLimited`; no session (authorization returns nil) ⇒ `.signInRequired` and no request sent.
  - `DeleteAccountUseCaseTests`: a recording repository and cache; success calls the repository once with the code, then `removeAll()` once, in that order; a repository error propagates and `removeAll()` is never called; a `nil` cache succeeds.
  - `FeedStartupCacheTests` (same style as the file's existing tests): after `store`, `SessionFeedStartupCache.removeAll()` leaves no file under the cache directory and `cachedVideos()` is empty, and a later `store` works again; a `store` whose download is still suspended when `removeAll()` runs (hold the download closure on a continuation, resume it afterwards) leaves nothing on disk.
- [ ] **Step 2: Run** the three suites. Expected: FAIL (build errors for the missing types).
- [ ] **Step 3: Implement** the types above. `AccountDeletionAPIClient.send` follows `LocationSharingAPIClient.send` (Bearer from `authorization?.bearerAuthorizationHeader()`, `AppLog` line without the code); a transport error (`URLError`) is not caught, the view model maps it. `FeedStartupCache.removeAll()` sets an `isRemoved` flag and deletes its directory, and `store` returns at once when the flag is set; `SessionFeedStartupCache.removeAll()` empties `caches` first, awaits each old cache's `removeAll()`, then deletes the whole `directory`.
- [ ] **Step 4: Run** the three suites. Expected: pass, with `Test run with N tests` matching the count you wrote.
- [ ] **Step 5: Commit** (the files above): "Add account deletion to the app's Domain and Data layers".

## Task 7: The local half of a sign out

**Files:**
- Modify: `Marauders-ios/Marauders/Presentation/Auth/AuthViewModel.swift`
- Create: `Marauders-ios/MaraudersTests/AuthViewModelAccountDeletionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  func finishAccountDeletion() async // the session ends locally; no call to the Worker
  #if DEBUG
  var isSignedInAsTestUser: Bool { get } // the stored user id is a `dev:` test user (DevLogin.isDevUserID)
  #endif
  ```

- [ ] **Step 1: Write the failing tests** (mirror `AuthViewModelUploadHooksTests`: its `signedInHarness`, `SignOutSessionStorage`, `FakeClipUploader`):
  - `finishingADeletionClearsTheSessionAndSignsOut`: the stored token and user id are nil, `isSignedIn` is false, `errorMessage` is nil.
  - `itMakesNoCallToTheWorker`: with a counting double for the location-sharing repository set as `stopSharingOnSignOut` and an auth API double that counts `revokeRefreshToken`, both counts are 0 afterwards.
  - `itDropsThePendingUploadWhileTheSessionIsStillStored`: `uploader.discards == 1` and the token was still stored when the discard arrived.
  - `aStuckUploadHookNeverHoldsItBack`: with `uploadHookTimeout` of 50 ms and a discard that never returns, the call still finishes and the viewer is signed out.
  - Debug only: `isSignedInAsTestUser` is true for a stored user id `dev:ui`, false for an Apple-style id, false with nothing stored.
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/AuthViewModelAccountDeletionTests`. Expected: FAIL (build error).
- [ ] **Step 3: Implement.** `finishAccountDeletion()` is `signOut()` without the Worker half: set `signsInAsTestUserOnSimulator = false`, `await discardThePendingUpload()`, `clearStoredSession()`, `isSignedIn = false`, `errorMessage = nil`, one `AppLog.info("auth", …)` line. `isSignedInAsTestUser` reads `sessionStore.readUserID()`.
- [ ] **Step 4: Run** the suite and `AuthViewModelUploadHooksTests`, `AuthViewModelTests`. Expected: pass.
- [ ] **Step 5: Commit:** "Add the local half of a sign out for a deleted account".

## Task 8: The view model of the deletion sheet

**Files:**
- Create: `Marauders-ios/Marauders/Presentation/Settings/AccountDeletionViewModel.swift`, `Marauders-ios/MaraudersTests/AccountDeletionViewModelTests.swift`

**Interfaces:**
- Consumes: `DeleteAccountUseCase`, `AccountDeletionError` (Task 6).
- Produces:
  ```swift
  @MainActor @Observable final class AccountDeletionViewModel {
      enum Phase: Equatable { case idle, deleting, failed(String), deleted }
      private(set) var phase: Phase
      @ObservationIgnored var onAccountDeleted: (@MainActor () async -> Void)?
      init(deleteAccount: DeleteAccountUseCase)
      func handleAuthorization(_ result: Result<ASAuthorization, Error>) async // converts, then calls handleAppleResult
      func handleAppleResult(_ result: Result<Data?, Error>) async              // what the tests drive
      func delete(authorizationCode: String?) async                             // also what the Debug-only buttons call, with nil
      func reset()                                                              // back to .idle, except while .deleting
  }
  ```

- [ ] **Step 1: Write the failing tests** (a repository double whose result and suspension a test controls):
  - success: `phase == .deleted` and `onAccountDeleted` ran once, after the phase became `.deleted`; on failure it never runs.
  - error mapping: each `AccountDeletionError` case ⇒ `.failed(error.errorDescription)`; a `URLError(.timedOut)` ⇒ `.failed` with the `.couldNotFinish` text.
  - double tap (RF 5): while the repository is suspended, a second `delete` returns at once and the repository was called once.
  - cancelled Apple sheet (`NSError` domain `ASAuthorizationError.errorDomain`, code `ASAuthorizationError.canceled.rawValue`) ⇒ phase `.idle`, no request; any other Apple failure ⇒ `.failed` with the `.appleNotConfirmed` text, no request.
  - no code (RF 5): `.success(nil)`, `.success(Data())` and `.success(Data([0xFF, 0xFE]))` ⇒ `.failed` with the `.appleNotConfirmed` text and zero repository calls; `.success(Data("abc.def".utf8))` ⇒ the repository received `"abc.def"`.
  - a failed attempt followed by a successful one from the same sheet ⇒ `.failed` then `.deleted`, callback once.
  - `reset()` returns `.failed` to `.idle` and does nothing while `.deleting`.
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/AccountDeletionViewModelTests`. Expected: FAIL. **Step 3: implement** the view model (it imports AuthenticationServices, like `AuthViewModel`); run again, expected pass.
- [ ] **Step 4: Commit:** "Add the view model of the deletion sheet".

## Task 9: The sheet, the Settings row, the wiring and the strings

**Files:**
- Create: `Marauders-ios/Marauders/Presentation/Settings/DeleteAccountSheet.swift`
- Modify (under `Marauders-ios/Marauders/`): `Presentation/Settings/SettingsView.swift`, `Presentation/Main/ContentView.swift` (and its `#Preview`), `Presentation/Splash/AppRootView.swift`, `Composition/AppDependencyContainer.swift`, `Resources/Localizable.xcstrings`
- Test: modify `Marauders-ios/MaraudersTests/AppDependencyContainerWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 6 to 8.
- Produces: `SettingsView(…, onDeleteAccount: () -> Void = {})`; `ContentView(…, accountDeletionViewModel: AccountDeletionViewModel)`; `AppDependencyContainer.init(…, accountDeletionRepository: AccountDeletionRepository? = nil)` and `let accountDeletionViewModel: AccountDeletionViewModel`.

- [ ] **Step 1: Write the failing wiring tests** (in `AppDependencyContainerWiringTests`, with `SignOutSessionStorage`, `MemoryRefreshTokenStore` and a stub repository that succeeds or fails on demand):
  - `finishingADeletionSignsTheContainersViewerOut`: after `await container.accountDeletionViewModel.delete(authorizationCode: "c")` the stored token and user id are nil, `authViewModel.isSignedIn` is false and `phase == .deleted`;
  - `aFailedDeletionKeepsTheSession`: the session and `isSignedIn` are untouched and `phase` is `.failed`;
  - `theDeletionClearsThePersonalFeedCache`: put a marker file inside the real `Caches/PersonalFeedStartup-v2` folder, run a successful deletion, and the marker is gone.
- [ ] **Step 2: Run** `-only-testing:MaraudersTests/AppDependencyContainerWiringTests`. Expected: FAIL (build error).
- [ ] **Step 3: Implement the container wiring.** Resolve the repository like the likes' (an injected one, else `UITestAccountDeletionRepository(fails: ProcessInfo.processInfo.arguments.contains("UITEST_ACCOUNT_DELETION_FAILS"))` when `isUITesting` and not `usesRejectedUITestSession`, else `DefaultAccountDeletionRepository(apiClient: AccountDeletionAPIClient(client: transport, authorization: apiAuthorization))`); build `DeleteAccountUseCase` with `feedCache: AppRuntimeConfiguration.isUITesting || feedRepository != nil ? nil : FeedStartupCache.shared` (the feed's own condition, `AppDependencyContainer.swift:165`); build the view model; set `accountDeletionViewModel.onAccountDeleted = { [weak authViewModel] in await authViewModel?.finishAccountDeletion() }` next to the other callbacks.
- [ ] **Step 4: Implement the screens.**
  - `SettingsView`: after the Location sharing section, `if isSignedIn` an "Account" section with a destructive "Delete Account" button (`settings.deleteAccount`) calling `onDeleteAccount()`, footer "Permanently deletes your account and everything in it.".
  - `ContentView`: new `accountDeletionViewModel` parameter, `@State private var showingDeleteAccount = false`, `SettingsView(…, onDeleteAccount: { showingDeleteAccount = true })`, and `.sheet(isPresented: $showingDeleteAccount, onDismiss: { accountDeletionViewModel.reset() }) { DeleteAccountSheet(…) }`; `AppRootView` and the `#Preview` pass the new parameter.
  - `DeleteAccountSheet(viewModel:isTestUser:onClose:)`: the layout and texts of §7, one view per phase; `SignInWithAppleButton(.continue)` with `requestedScopes = []` whose completion runs `Task { await viewModel.handleAuthorization(result) }`; Cancel (`deleteAccount.cancel`) disabled while deleting; `.interactiveDismissDisabled(viewModel.phase == .deleting)`; the identifiers of Global Constraints; the error text red; Done calls `onClose`. `#if DEBUG`: with `AppRuntimeConfiguration.isUITesting` a plain button (`Text(verbatim: "Confirm deletion (UI test)")`) takes the Apple button's place and its identifier `deleteAccount.appleButton`; otherwise, when `isTestUser`, a plain `Text(verbatim: "Delete test user")` button (`deleteAccount.testUser`) replaces it; both call `viewModel.delete(authorizationCode: nil)`. `ContentView` passes `isTestUser` from `authViewModel.isSignedInAsTestUser` under `#if DEBUG` and `false` otherwise.
  - Strings: every new English text of §7 (sheet, progress, confirmation, the six error texts) goes in `Localizable.xcstrings` with Thai, reusing existing keys where they exist ("Cancel", "Done", "Your session has ended. Please sign in again."). List the Thai texts in your report to the owner for review, like the rest of the Thai table.
- [ ] **Step 5: Run** `AppDependencyContainerWiringTests`, `LocalizationCatalogTests`, `StringCatalogAuditTests`, `StringCatalogLayoutTests`, `LocalizedErrorTextTests`, and `Marauders-ios/Scripts/check-layers.sh --strict`. Expected: pass, and the checker exits 0 with no new exception.
- [ ] **Step 6: Commit:** "Add the Delete Account row, the sheet and their wiring".

## Task 10: UI tests and the accessibility audit

**Files:**
- Modify: `Marauders-ios/MaraudersUITests/MaraudersUITests.swift`, `Marauders-ios/MaraudersUITests/MaraudersAccessibilityUITests.swift`

- [ ] **Step 1: Write the UI tests** (helpers `launchApp(extraArguments:)`, `openSettings(app)`; the default `UITEST` launch is signed in):
  - `testDeleteAccountRowShowsOnlyWhenSignedIn`: `settings.deleteAccount` exists when signed in and does not with `UITEST_GUEST`.
  - `testDeleteAccountSheetOpensAndCancelClosesIt`: the row opens `deleteAccount.sheet`; `deleteAccount.cancel` closes it and Settings is still there.
  - `testConfirmingTheDeletionSignsTheViewerOutAndShowsTheConfirmation`: tap `deleteAccount.appleButton` (the plain UI-test button), wait for `deleteAccount.done`, tap it; the Profile tab then shows `profile.signInRequired`.
  - `testAFailedDeletionShowsTheMessageAndKeepsTheSession`: launch with `UITEST_ACCOUNT_DELETION_FAILS`; after the tap, `deleteAccount.error` exists with "We couldn't finish deleting your account. Please try again."; cancel; the Profile tab still shows `profile.root`.
  - In the accessibility file: `testDeleteAccountSheetPassesTheStableAudits`, next to `testSettingsPassesTheStableAudits`, using its `launch`, `toSettings` and `audit(app)` helpers on the open sheet (idle phase).
- [ ] **Step 2: Run each new UI test alone** with `-only-testing:MaraudersUITests/MaraudersUITests/<test>` (and the accessibility one the same way). Expected: pass. A full UI run takes 16 to 34 minutes: do it once in Step 3.
- [ ] **Step 3: Run the whole gate.** The full unit suite (`-only-testing:MaraudersTests`, expect 1347 plus every new test, all green) and the full UI suite (expect 79 plus the five new, all green but the known simulator-only red); `Scripts/check-layers.sh --strict`; `cd backend && npm test`.
- [ ] **Step 4: Commit:** "Test the deletion flow in the UI and in the accessibility audit".

## Task 11: Write it down

**Files:**
- Create: `docs/adr/011-account-deletion.md`
- Modify: `docs/adr/README.md` (one row), `ARCHITECTURE.md`, `README.md`, `deployment/README.md`, `docs/ci-cd.md`

- [ ] **Step 1: ADR-011** in the style of ADR-007 and ADR-010: the decision and the alternatives of §"Approaches considered"; the order Apple, R2, rows and the invariant it buys; the three Worker secrets; the clip cap and why; the evidence you gathered (which Postgres form passed the PGlite proof and on which versions, Apple's confirmed parameter names, the `waitUntil` finding of Task 4 Step 1); Known limits 1 to 9 of the spec. Add its row to `docs/adr/README.md`.
- [ ] **Step 2: `ARCHITECTURE.md`:** a route row after `PATCH /v1/users/me`; the `account-delete` row among the rate limits; the three names in the secrets row (line 99) and the box (line 86); a short "Account deletion" section (flow, order, what each failure leaves behind); the one sentence of Known limit 3 (a failure after the revoke can sign the person out locally; signing in again with the same Apple ID reaches the same account, and Delete Account works again).
- [ ] **Step 3: `README.md`, `deployment/README.md`, `docs/ci-cd.md`** (the last two are in Thai, like the rest of those files): add the three secrets where `APPLE_CLIENT_ID` is listed (`README.md:107`, `deployment/README.md:149-153` and `:220`, `docs/ci-cd.md:246`); in `deployment/README.md` add how the Sign in with Apple key is made (Certificates, Identifiers & Profiles → Keys, Sign in with Apple, the key linked to the app's App ID; the `.p8` can be downloaded once), where the key id and team id are, and the rollout order of "Rollout" below.
- [ ] **Step 4: Run** `cd backend && npm test` (the docs changed no code, so it must still pass) and re-read each edited doc once. **Step 5: Commit:** "Write account deletion down: ADR-011, architecture, deployment".

---

## Rollout (the owner's steps, not build tasks)

Nothing below happens without the owner's explicit yes, one step at a time, after Task 11 and a review of the branch. Never run a step "because the plan says so".

- **R0 (optional, read-only):** count `feed_videos` rows whose `stream_url` ends in `.m3u8` on production (a script outside the repo that imports `loadVars` and `parseCli` from `backend/scripts/lib/targets.mjs` by absolute path); the count decides whether check A includes an HLS test clip.
- **R1, secrets and cap:** the owner creates the Sign in with Apple key in the developer portal; the three secrets are set on production with `wrangler secret put`, the private key from a file on stdin, no value in chat or in a log. The owner tells which Cloudflare plan the Worker is on; read Cloudflare's current subrequest limit for it, compute the cap with a margin (§6 gives about 2 subrequests per plain clip, 4 per HLS clip, about 10 fixed; do not trust that arithmetic), change `MAX_CLIPS_PER_DELETION` and commit it with its reason.
- **R2, merge and deploy:** the owner says merge; before deploying, record the active version with `cd backend && npx wrangler deployments list` as the rollback target; deploy with `cd backend && npm run deploy:production -- --confirm production` (the script runs the tests first and checks the Cloudflare login itself). No migration. Rollback: `npx wrangler rollback <version id>` (the route is a 405 again and the app shows "not available").
- **R3, check A (no Apple):** on the Simulator with the `Marauders Staging` Debug build, sign in as a `dev:` test user, upload one or two test clips (plus one HLS test clip if R0 found HLS clips in production), then Settings → Delete Account → "Delete test user". Expected: "Your account was deleted"; the clips no longer appear in `GET /v1/feed`; their R2 keys are gone; the `app_users` row is gone (read-only checks). This is also the real proof that a `DELETE` with a JSON body survives URLSession, Cloudflare and the Worker (a stripped body would answer 400); if it does not, the fallback is `POST /v1/users/me/delete`, a change to Tasks 4 to 6.
- **R4, check B (real Apple):** on a phone, with an Apple account the owner accepts to lose, delete the account through the Apple sheet, then confirm in the iPhone's Apple ID settings that Marauders no longer appears under Sign in with Apple; signing in again must create a fresh, empty account. This is the only proof of the revoke, because Apple answers 200 whatever it is given.
- **R5, TestFlight:** only after checks A and B; the owner starts Jenkins and presses Build Now.

## Not in this plan (each its own decision)

Report and block; the Privacy Policy and Terms links, the privacy manifest and the App Privacy answers; the fix of `DELETE /v1/videos/:id`, which deletes only the playlist of an HLS clip and leaves its segments and original public (§"Found while reviewing"); committing the design doc and this plan.
