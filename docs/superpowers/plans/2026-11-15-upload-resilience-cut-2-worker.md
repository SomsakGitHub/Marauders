# Upload Resilience, Cut 2 (Worker): an Idempotency Key for `POST /v1/videos` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A retried upload never makes a second clip. `POST /v1/videos` accepts an `Idempotency-Key` header and answers a key it has already stored with the clip it stored.

**Architecture:** Migration 023 adds `feed_videos.upload_key` and a partial unique index on `(owner_user_id, upload_key)`. `handleVideoUpload` reads the header before it touches the body, and a stored key answers 200 at once. A new key goes through today's work, and `insertFeedVideo` stores the key with `ON CONFLICT … DO NOTHING`; the loser of a race deletes its R2 object and answers with the winner's clip. A request without the header takes today's path with today's SQL.

**Tech Stack:** Cloudflare Worker (TypeScript), `@neondatabase/serverless`, R2, esbuild plus `node:test` on the fake Neon driver.

**Spec:** `docs/superpowers/specs/2026-11-15-upload-resilience-design.md`, sections "Design: cut 2, the Worker", "Rollout, order and rollback" and "Verification". Read it first. The app half is the sibling plan `docs/superpowers/plans/2026-11-15-upload-resilience-cut-2-app.md`. This plan needs nothing from it and is backwards compatible, so it can land first; the app plan's device checks need it deployed.

## Global Constraints

- **Scope:** `backend/` and docs only. No app file changes. A request **without** `Idempotency-Key` behaves as today and runs today's SQL byte for byte, so it never reads or writes `upload_key` (a Worker deployed before the migration still serves old app builds).
- **Header:** `Idempotency-Key`. The value is a UUID in the shape `UUID_RE` in `src/validation.ts` accepts (36 characters, version 1 to 5), lower-cased before use. Anything else, the empty string included: 400 `Idempotency-Key must be a UUID`.
- **Order inside `handleVideoUpload`:** the two configuration 503s, then the header, then the stored-key lookup, then today's multipart checks. A replay carries no multipart body, so the header and the lookup come **before** the `Content-Type` check and before `request.formData()`.
- **Stored key (this owner):** 200 `{ item }` in the shape a new upload answers, with no body read, no R2 call and no insert. A new clip answers 201 as today.
- **Key scope:** `(owner_user_id, upload_key)`. Another account's identical key is a new key.
- **Race:** the keyed insert is `INSERT … ON CONFLICT (owner_user_id, upload_key) WHERE upload_key IS NOT NULL DO NOTHING RETURNING …`. No row back means a request with the same key won: this request deletes the R2 object it just wrote and answers 200 with the winner's clip.
- **Rate limit:** `upload`, 10 per 60 s, still runs before the handler. A replay counts.
- **Migration style:** idempotent (`IF NOT EXISTS`), and no `;` inside a comment, because `scripts/migrate.mjs` splits on `;` before it strips `--` comments. It replays every file on each run.
- **Style:** the neighbours' TypeScript (2 spaces, double quotes); `npm run typecheck` stays clean. Tests are bundled by esbuild and are not type-checked (`tsconfig.json` includes `src/` only).
- **Git:** stage named files only, never `git add -A`, never `backend/scripts/reset-all-data.sql`. This plan touches no file of the app, so the owner's uncommitted edit in `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` is never involved. Commit, push, merge, migration and deploy each need the owner's separate yes.

## Review Focus

Five inputs the spec implies and a happy-path test would miss, most likely first, each pinned by a test:

1. **Two requests with one key at once** (the app taps Try again while the Worker still processes the first request). Expect one clip row, no leftover R2 object from the loser, and a clip in both answers. Pinned by Task 2 `twoRequestsWithOneKeyLeaveOneClipAndTheLoserDeletesItsObject` and `aLoserWhoseWinnerWasDeletedAnswers500AndLeavesNoObject`.
2. **A key that belongs to another account.** Expect the second account to get its own new clip and never the first account's. Pinned by Task 2 `aKeyBelongsToTheAccountThatSentIt`.
3. **A malformed or empty header** (empty string, braces, a trailing character, 37 characters). Expect 400 before anything is read or stored, never "treated as no header", which would lose the duplicate protection silently. Pinned by Task 1 `parseUploadIdempotencyKeyRefusesWhatIsNotAUuid` and Task 2 `aHeaderThatIsNotAUuidIsRefusedBeforeAnythingIsReadOrStored`.
4. **A replay with no body and no multipart `Content-Type`** (the app's way to ask for a clip whose answer it lost), for a key that was never stored. Expect a clean 400 and nothing created. Pinned by Task 2 `aReplayWithoutABodyForAnUnknownKeyIsRefusedAndStoresNothing`.
5. **The database fails at the lookup.** Expect 500 and nothing written (no object, no row), so a retry is safe; falling through to a new upload would risk the duplicate the key exists to prevent. Pinned by Task 2 `aFailedLookupAnswers500AndStoresNothing`.

Also pinned: a request without the header runs the old SQL (`aRequestWithoutTheHeaderRunsTodaysSql`), the order of rate limit and lookup (`aReplayCountsAgainstTheUploadRateLimit`), the uppercase key stored lower-case, and the real SQL on a real Postgres (Task 3).

**Known limit, not built (goes into ADR 008):** if the insert commits but its answer is lost on the way back, the existing rollback deletes the R2 object although the row exists. Before this change a retry made a second, healthy clip beside the broken one; now the retry returns the broken one. It needs a connection failure at the moment of the commit. Handling it means looking the row up before the rollback.

## How to run things

- **Paths** are relative to `backend/` except `docs/...`, `ARCHITECTURE.md`, `README.md` and `deployment/README.md`, which are relative to the repository root. Commands run from `backend/`.
- **New suite:** `npm run test:upload-idempotency`. **Typecheck:** `npm run typecheck`. **Everything the owner runs before a deploy:** `npm run typecheck && npm run test:feed && npm run test:dubbed-audio && npm run test:dev-auth && npm run test:comments && npm run test:likes && npm run test:follows && npm run test:auth-refresh && npm run test:upload-idempotency`.
- A task's "Run" step names the suite and the expected result. A test file that does not compile fails the run with an esbuild error, which is the expected state of every "see it fail" step.
- **In a worktree** `backend/node_modules` does not exist (git-ignored). Link the main checkout's instead of installing: `ln -s /Users/tiscomacnb2486/Desktop/Marauders/backend/node_modules backend/node_modules`. No download. `git status` must show nothing new afterwards.

## File Structure

| Area | Create | Modify |
|------|--------|--------|
| SQL | `backend/sql/023_feed_video_upload_key.sql` | `backend/scripts/migrate.mjs` (one list entry) |
| Validation | | `backend/src/validation.ts` (`parseUploadIdempotencyKey`) |
| Database layer | | `backend/src/db/feed.ts` (`UploadKeyConflictError`, `findFeedVideoByUploadKey`, keyed `insertFeedVideo`) |
| Route | | `backend/src/routes/upload.ts` (`handleVideoUpload`) |
| Tests | `backend/test/uploadIdempotency.test.ts`, `backend/scripts/test-upload-idempotency.mjs` | `backend/package.json` (`test:upload-idempotency`) |
| Docs | | `ARCHITECTURE.md`, `README.md`, `deployment/README.md` |

## Calls this plan makes (beyond the spec; the owner may overrule any)

1. **`parseUploadIdempotencyKey` lives in `validation.ts`** beside the other upload parsers and uses the file's `UUID_RE`.
2. **`insertFeedVideo` keeps every existing call working.** The key is a new trailing parameter `uploadKey: string | null = null`, and a conflict is a thrown `UploadKeyConflictError`, not a nullable return, so the four existing callers (`likes.test.ts`, `follows.test.ts`, `commentsRoutes.test.ts`, `scripts/test-audio-assessment.mjs`) are not touched.
3. **Two INSERT statements.** The no-key statement stays byte for byte as it is; the keyed one is a second statement. The duplication is on purpose: old builds never touch `upload_key`.
4. **The stored clip is answered with the same constants a fresh insert uses for the counters** (`likeCount` 0, `commentCount` 0, `postedByViewer` true), with the author's live handle (`COALESCE(u.handle, v.author_name)`, as the feed reads it). The app only uses the id, and the feed is reloaded after an upload.
5. **A lookup that fails answers 500 `upload lookup failed`** and writes nothing (Review Focus 5).
6. **An empty header is a 400**, not "no header".
7. **The real-Postgres check (Task 3) is a throwaway script outside the repo.** The repo has no PGlite dependency and one check does not justify one. It needs the owner's yes to install PGlite from the npm cache.
8. **The lost-answer-after-commit limit is documented, not fixed** (see "Known limit").

## Before Task 1

- [ ] Ask the owner once, in one message: (a) commit the two cut 2 plan files under `docs/superpowers/plans/` as one commit on `main`; (b) work in a worktree on its own branch, `claude/upload-resilience-cut-2-worker` (`superpowers:using-git-worktrees`), with `node_modules` linked as above; (c) may each task's local commit below be made as the task passes. A push, the merge, migration 023 and the Worker deploy are asked separately, each time.

---

### Task 1: The key in the database layer

**Files:**
- Create: `sql/023_feed_video_upload_key.sql`, `scripts/test-upload-idempotency.mjs`, `test/uploadIdempotency.test.ts`
- Modify: `scripts/migrate.mjs`, `package.json`, `src/validation.ts`, `src/db/feed.ts`

**Interfaces:**
- Produces:
  ```ts
  // validation.ts
  /** null (no header) stays null; a UUID comes back lower-cased; anything else, "" included, throws
   *  FeedValidationError("Idempotency-Key must be a UUID"). */
  export function parseUploadIdempotencyKey(raw: string | null): string | null;
  // db/feed.ts
  export class UploadKeyConflictError extends Error {}
  export async function findFeedVideoByUploadKey(
    databaseUrl: string, ownerUserId: string, uploadKey: string,
  ): Promise<FeedItemJson | null>;
  export async function insertFeedVideo(
    databaseUrl: string, streamUrl: string, latitude: number, longitude: number, ownerUserId: string,
    caption?: string, audioAssessment?: Record<string, unknown> | null,
    uploadKey?: string | null,            // new, last, default null
  ): Promise<FeedItemJson>;               // with a key and no row back: throws UploadKeyConflictError
  ```
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing tests and the runner.**
  - `scripts/test-upload-idempotency.mjs`: a copy of `scripts/test-likes.mjs` with `test/uploadIdempotency.test.ts` as the entry point, the temp folder prefix `marauders-upload-idempotency-` and the bundle name `uploadIdempotency.test.mjs`. `package.json`: `"test:upload-idempotency": "node scripts/test-upload-idempotency.mjs"` after `test:auth-refresh`.
  - `test/uploadIdempotency.test.ts`, a `describe("the upload key in the database layer")` with the imports and helpers of `test/likes.test.ts` (`queries`, `resetFakeNeon`, `respondWith`; `beforeEach(resetFakeNeon)`). Constants: `OWNER = "11111111-1111-4111-8111-111111111111"`, `KEY = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"`, a `clipRow()` helper returning `{ id, stream_url: "https://api.test/v1/media/videos/x.mov", latitude: 13.75, longitude: 100.5, author_name: "@alice", avatar_url: null, caption: "", audio_assessment: null }`.
    - `parseUploadIdempotencyKeyRefusesWhatIsNotAUuid`: `null` gives `null`; `KEY.toUpperCase()` gives `KEY`; each of `""`, `"abc"`, `` `{${KEY}}` ``, `` `${KEY} ` ``, `` `${KEY}a` `` throws `FeedValidationError` with the message `Idempotency-Key must be a UUID`.
    - `insertWithoutAKeyRunsTodaysStatement`: `respondWith(() => [clipRow()])`; `insertFeedVideo(DB, url, 1, 2, OWNER)`; the one recorded query matches `/INSERT INTO feed_videos/` and **not** `/upload_key/` and **not** `/ON CONFLICT/`.
    - `insertWithAKeyStoresItAndSurvivesARace`: `insertFeedVideo(DB, url, 1, 2, OWNER, "", null, KEY)`; the query text matches `/ON CONFLICT \(owner_user_id, upload_key\) WHERE upload_key IS NOT NULL DO NOTHING/`, its values include `KEY` and `OWNER`, and the returned item has `postedByViewer === true`. With `respondWith(() => [])` the same call rejects with `UploadKeyConflictError`.
    - `findFeedVideoByUploadKeyScopesByOwnerAndKey`: with `respondWith(() => [clipRow()])` the query text matches `/WHERE v\.owner_user_id = \?::uuid AND v\.upload_key = \?::uuid/` and its values are `[OWNER, KEY]`; the item has the row's id, `likeCount === 0`, `commentCount === 0`, `postedByViewer === true`. With `[]` it returns `null`.
- [ ] **Step 2: Run** `npm run test:upload-idempotency`. Expected: an esbuild error that `parseUploadIdempotencyKey`, `UploadKeyConflictError` and `findFeedVideoByUploadKey` are not exported.
- [ ] **Step 3: Implement.**
  - `sql/023_feed_video_upload_key.sql`: a comment header in the style of `022_refresh_tokens.sql` (what the key is, NULL for older clips and older builds, scoped to the account; no `;` in any comment), then exactly the two statements of the spec: `ALTER TABLE feed_videos ADD COLUMN IF NOT EXISTS upload_key UUID;` and `CREATE UNIQUE INDEX IF NOT EXISTS feed_videos_owner_upload_key_uidx ON feed_videos (owner_user_id, upload_key) WHERE upload_key IS NOT NULL;`. Add `"../sql/023_feed_video_upload_key.sql",` after the 022 entry of `scripts/migrate.mjs`, with the indentation of its neighbours.
  - `parseUploadIdempotencyKey`: `null` returns `null`; otherwise `raw.length !== 36 || !UUID_RE.test(raw)` throws, else return `raw.toLowerCase()`.
  - `db/feed.ts`: factor the mapping from a returned row to a `FeedItemJson` that `insertFeedVideo` ends with into one private function, used by both `insertFeedVideo` and `findFeedVideoByUploadKey` (the counters 0, `postedByViewer` true, `authorFollowedByViewer` false, `country` null). With `uploadKey === null` `insertFeedVideo` runs today's statement unchanged. With a key it runs the same insert plus `upload_key` (value `${uploadKey}::uuid`) and `ON CONFLICT (owner_user_id, upload_key) WHERE upload_key IS NOT NULL DO NOTHING`, and throws `UploadKeyConflictError` when no row comes back. `findFeedVideoByUploadKey` selects the columns `listUserFeedVideos` selects for a clip's card (`id, stream_url, latitude, longitude, COALESCE(u.handle, v.author_name) AS author_name, u.avatar_url, caption, audio_assessment`) from `feed_videos v LEFT JOIN app_users u ON u.id = v.owner_user_id` where `v.owner_user_id = ${ownerUserId}::uuid AND v.upload_key = ${uploadKey}::uuid`.
- [ ] **Step 4: Run** `npm run test:upload-idempotency`, then `npm run typecheck`, `npm run test:likes`, `npm run test:follows`, `npm run test:comments` (they call `insertFeedVideo`) and `node scripts/test-audio-assessment.mjs`. Expected: all pass, and `grep -c "upload_key" src/db/feed.ts` shows the new statements only.
- [ ] **Step 5: Commit:** `git add backend/sql/023_feed_video_upload_key.sql backend/scripts/migrate.mjs backend/scripts/test-upload-idempotency.mjs backend/package.json backend/src/validation.ts backend/src/db/feed.ts backend/test/uploadIdempotency.test.ts` → "Store an upload key with a clip and look a clip up by it".

### Task 2: The handler answers a stored key and survives a race

**Files:**
- Modify: `src/routes/upload.ts`, `test/uploadIdempotency.test.ts`

**Interfaces:**
- Consumes: Task 1's `parseUploadIdempotencyKey`, `findFeedVideoByUploadKey`, `UploadKeyConflictError` and the keyed `insertFeedVideo`.
- Produces: `handleVideoUpload(request: Request, env: Env, ownerUserId: string): Promise<Response>` (signature unchanged) with the behaviour of "Global Constraints".

- [ ] **Step 1: Write the failing tests** in a second `describe("POST /v1/videos with an Idempotency-Key")`. Helpers: the `tokenFor` and `JWT_SECRET` of `test/likes.test.ts`; `fakeBucket()` returning `{ puts: string[], deletes: string[], put, delete }`; `env = { DATABASE_URL, JWT_SIGNING_SECRET, VIDEOS: bucket }`; `uploadRequest({ userId, key?, body })` building a POST to `https://api.test/v1/videos` with `Authorization: Bearer`, the `Idempotency-Key` header when given, and a body that is either a `FormData` (`latitude "13.75"`, `longitude "100.5"`, `file` = `new File([new Uint8Array(16)], "clip.mov", { type: "video/quicktime" })`, which skips the MP4 fast-start pass) or nothing. The responder answers `/rate_limit_counters/` with `[{ count: 1 }]`, the lookup (`/v\.upload_key = \?::uuid/`) and the insert (`/INSERT INTO feed_videos/`) from per-test data, and throws on any other statement. Each test calls `worker.fetch(request, env)` and keeps the `Request` to read `request.bodyUsed` afterwards.
  - `aRequestWithoutTheHeaderRunsTodaysSql`: 201; the recorded statements are the rate limit and one insert whose text does not contain `upload_key`; `bucket.puts.length === 1`.
  - `aHeaderThatIsNotAUuidIsRefusedBeforeAnythingIsReadOrStored`: `Idempotency-Key: not-a-uuid` and again with an empty value; both 400 with `{ error: "Idempotency-Key must be a UUID" }`; `request.bodyUsed === false`; no put, no insert, no lookup.
  - `aKeyThatIsAlreadyStoredAnswers200WithTheStoredClipAndReadsNothing`: the lookup returns `clipRow()`; 200, `item.id` equals the row's id, `request.bodyUsed === false`, `puts` and `deletes` empty, no insert.
  - `aReplayWithoutABodyAnswersFromTheStoredKey`: no body and no multipart type, the lookup returns the row; 200 with the same item.
  - `aReplayWithoutABodyForAnUnknownKeyIsRefusedAndStoresNothing`: no body, the lookup returns `[]`; 400 `expected multipart form data`; no put, no insert.
  - `aNewKeyIsStoredWithTheUploadAndAnswers201`: key sent in upper case; the lookup returns `[]`; 201; the insert's values include the **lower-case** key; the insert text matches `/ON CONFLICT \(owner_user_id, upload_key\)/`; one put.
  - `twoRequestsWithOneKeyLeaveOneClipAndTheLoserDeletesItsObject`: the first lookup returns `[]`, the insert returns `[]` (the key was taken meanwhile), the second lookup returns the winner's row; 200 with the winner's id; `deletes` equals `puts` (the object this request wrote is gone).
  - `aLoserWhoseWinnerWasDeletedAnswers500AndLeavesNoObject`: as above but the second lookup returns `[]`; 500; `deletes` equals `puts`.
  - `aKeyBelongsToTheAccountThatSentIt`: the lookup responder returns the row only when its first value is `ALICE`. Alice's request answers 200 with the stored clip; Bob's request with the same key answers 201, Bob's id is the lookup's and the insert's owner value.
  - `aFailedLookupAnswers500AndStoresNothing`: the lookup throws; 500 `upload lookup failed`; `request.bodyUsed === false`; no put, no insert.
  - `aReplayCountsAgainstTheUploadRateLimit`: the rate limit answers `{ count: 11 }`; 429; no lookup ran.
- [ ] **Step 2: Run** `npm run test:upload-idempotency`. Expected: the new tests fail (the header is ignored today: 201 where 200 is expected, 400 `expected multipart form data` where the replay should answer 200).
- [ ] **Step 3: Implement `handleVideoUpload`** in `src/routes/upload.ts`.
  - After the two 503 checks and before the `Content-Type` check: parse the header (a `FeedValidationError` answers `jsonError(error.status, error.message)`); with a key, call `findFeedVideoByUploadKey` and answer `jsonOk({ item }, 200)` when it finds one; a thrown lookup logs `console.error("upload key lookup failed", …)` and answers `jsonError(500, "upload lookup failed")`.
  - Pass `uploadKey` as the last argument of `insertFeedVideo`. In the insert's `catch`, delete the R2 object first (today's best-effort rollback), then: when the error is an `UploadKeyConflictError`, look the key up again (a failure here logs and falls to the 500 below) and answer `jsonOk({ item }, 200)` with the winner's clip, else answer `jsonError(500, "database write failed: upload key conflict")`; any other error keeps today's 500.
  - Everything else, the 201 answer included, stays as it is.
- [ ] **Step 4: Run** `npm run test:upload-idempotency`, `npm run typecheck`, `npm run test:feed`, `npm run test:likes`. Expected: all pass.
- [ ] **Step 5: Commit:** `git add backend/src/routes/upload.ts backend/test/uploadIdempotency.test.ts` → "Answer a repeated upload with the clip it already stored".

### Task 3: Run the two statements on a real Postgres (throwaway, nothing committed)

**Files:** none in the repo. The script lives in the scratch folder.

The fake driver checks the shape of a statement, not its SQL. This task runs the real migration and the real statements once before anything touches the live database. It needs PGlite (`@electric-sql/pglite`, Postgres in WASM), which an earlier check of this project found in the owner's npm cache.

- [ ] **Step 1: Ask the owner** for a yes to install PGlite into a fresh scratch folder with `npm install --offline --ignore-scripts @electric-sql/pglite`. If the cache no longer holds it the command fails, and a download is a second question for the owner.
- [ ] **Step 2: Write the script** in the scratch folder. It (a) opens an in-memory PGlite, (b) runs `sql/001` to `sql/023` in the order of `scripts/migrate.mjs`, split the way `statementsFromFile` does, (c) runs 023 a second time, (d) bundles `src/db/feed.ts` with esbuild and `@neondatabase/serverless` replaced by a stand-in whose tagged template joins the strings with `$1…$n` and runs `pglite.query(text, values)`, so the **real** `insertFeedVideo` and `findFeedVideoByUploadKey` run, and (e) asserts the cases below. Two users are inserted into `app_users` first.
- [ ] **Step 3: Run it.** Expected, all true: 023 runs twice without an error; a keyed insert returns a row; the same `(owner, key)` again throws `UploadKeyConflictError` and leaves one row; the same key for the other user inserts a second row; two inserts without a key for one user both succeed (the index is partial); `findFeedVideoByUploadKey` returns user 1's clip for `(user 1, KEY_A)`, user 2's clip for `(user 2, KEY_A)`, and `null` for `(user 2, KEY_B)` when only user 1 holds `KEY_B`; `ALTER TABLE feed_videos DROP COLUMN upload_key` (the spec's rollback) runs and takes the index with it.
- [ ] **Step 4: Report** the PGlite and PostgreSQL versions and the case list in the hand-off. Delete the scratch folder. There is no commit.

### Task 4: Documentation and the whole Worker suite

**Files:**
- Modify: `ARCHITECTURE.md`, `README.md`, `deployment/README.md`

- [ ] **Step 1: Update the docs.**
  - `ARCHITECTURE.md`, the `POST /v1/videos` row of the API table: add the optional `Idempotency-Key` header (a UUID, lower-cased; the app sends one per upload and keeps it for every retry of that upload), the **200** answer with the stored clip for a key this account already stored (no body read, no R2), **201** for a new clip, **400** `Idempotency-Key must be a UUID`, and that the key lives in `feed_videos.upload_key` (migration 023). "Backend — video on write and read", "Upload": add the step that reads the header and answers a stored key before the file is validated. The `db:migrate` row: `001`…`023`. The `feed_videos` row of the data model: `upload_key UUID (023)` and its partial unique index on `(owner_user_id, upload_key)`.
  - `README.md`: the repo tree line "migrations 001–022" becomes "001–023".
  - `deployment/README.md`: add `npm run test:upload-idempotency` to the "ตรวจก่อน deploy" block, and a short paragraph in Thai in the style of the notes above it: ก่อน deploy Worker ที่รับ `Idempotency-Key` ให้รัน migration `023` ก่อน, เพราะคำขอที่ส่ง header นี้จะอ่านและเขียนคอลัมน์ `feed_videos.upload_key` และจะตอบ 500 ถ้ายังไม่มีคอลัมน์; คำขอที่ไม่มี header ไม่แตะคอลัมน์นี้ (แอปรุ่นเก่าไม่เสีย). Rollback: `wrangler rollback` เป็น 961faf99 (รุ่นที่ใช้งานอยู่ตอนนี้), และ `ALTER TABLE feed_videos DROP COLUMN upload_key` ถ้าต้องการเอาคอลัมน์ออก.
- [ ] **Step 2: Run everything the owner runs before a deploy** (the one-line command in "How to run things"). Expected: every suite passes; write down the test count of each.
- [ ] **Step 3: Check the diff.** `git diff --stat main...HEAD` lists only the files this plan names; `grep -rn "upload_key" backend/src` shows `db/feed.ts` and `routes/upload.ts` only.
- [ ] **Step 4: Commit:** `git add ARCHITECTURE.md README.md deployment/README.md` → "Document the upload idempotency key".

## After the last task (the owner's calls, not tasks)

- **Merge into `main`**, then **push**: each its own yes.
- **Migration 023** on the live database: `npm run db:migrate` from `backend/` (it replays every file, and every statement is idempotent). Afterwards check read-only that `feed_videos.upload_key` and the index `feed_videos_owner_upload_key_uidx` exist.
- **Worker deploy** (`npm run deploy`) after the migration. Write down the new version id; the rollback target is `961faf99-cc24-4b92-9b1c-38a440524baf`. A live check that proves the key needs a signed-in token (the app plan's device check does it: the same body sent twice with one key answers 201, then 200 with the same clip). Without a token the only live check is that the route is still alive: `curl -s -o /dev/null -w "%{http_code}" -X POST https://marauders-api.js6ctz7gtj.workers.dev/v1/videos` answers 401.
- **ADR 008** is written by the app plan's last task and covers both halves.
