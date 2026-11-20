# Environments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second environment, staging, and make every backend script, the app and CI say which environment they touch, with production's name, URL and data unchanged.

**Architecture:** `backend/environments.json` is the one table of environments (Worker, URL, bucket, vars file, confirmation phrases). Every backend script takes `--env` through one helper (`backend/scripts/lib/targets.mjs`) that reads only that environment's vars file, prints a banner and asks for a phrase. Staging is `[env.staging]` in `wrangler.toml`; production stays the top level. The app reads its URL from a user-defined build setting through Info.plist (Debug = staging, Release = production) and a Release build phase fails unless the URL is production's. GitHub Actions runs the offline backend tests and nothing else.

**Tech Stack:** Node 22 (`node:test`, `.mjs` scripts, esbuild fakes), wrangler 4.150.0 environments, `@neondatabase/serverless`, Swift 6 / SwiftUI / Swift Testing, Xcode build settings and Run Script phases, POSIX shell tests, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-19-environments-design.md` (approved by the owner on 2026-11-19, production logging = option 1). Executors read both files.

## Global Constraints

- Production never changes: Worker `marauders-api`, URL `https://marauders-api.js6ctz7gtj.workers.dev`, bucket `marauders-videos`, rate-limit namespace `1001`. `wrangler.toml` gets **no** `[env.production]` block (the Worker name and URL would change).
- Staging: Worker `marauders-api-staging`, URL `https://marauders-api-staging.js6ctz7gtj.workers.dev` (derived; confirmed at the first deploy), bucket `marauders-videos-staging`, namespace `1002`, vars file `backend/.dev.vars.staging`. Production's vars file is `backend/.dev.vars.production`.
- Node 22 and wrangler 4.150.0. No new dependency in the Worker, the backend scripts or the app.
- A wrangler environment inherits no bindings, `vars` or `observability`: staging repeats them. Every deploy passes the environment: `--env staging`, or `--env ""` for production. A bare `wrangler deploy` is never run or documented.
- Every `wrangler r2 object` call passes `--remote` (without it wrangler 4.150.0 acts on the local simulator).
- Confirmation phrases: `production` (migrate, deploy, `video:hls`, `test-upload` on production), `purge staging`, `purge production`. Typed at a prompt, or `--confirm "<phrase>"` when there is no terminal. No flag skips it. The assistant passes `--confirm` for production only after the owner's yes in chat for that very step.
- No script, test, log line, doc or chat message prints a secret value. Secrets move by shell redirection and `pbpaste`; random ones come from `openssl rand -base64 48`.
- Every cloud change (Neon database, bucket, secret, deploy, deleting production's `DEV_LOGIN_SECRET`) needs the owner's explicit yes at that moment. The assistant never deletes production data.
- Production logging stays off: observability is enabled for staging only (the owner's answer).
- GitHub Actions: no secret, no `pull_request_target`, `permissions: contents: read`, every action pinned to a full commit SHA.
- App: Debug builds use the staging URL, Release builds the production URL, through the user-defined build setting `MARAUDERS_API_BASE_URL` (the `INFOPLIST_KEY_` lines go away). Every target is iOS 27.0; app tests run on the iOS 27.2 simulator from a scratch mirror. The layer checker gets no new exception. Developer-only texts are `Text(verbatim:)` and, if the plain-string scan reports them, listed with a reason in `Marauders-ios/Scripts/plain-strings-allowlist.txt`.
- The owner's uncommitted `Marauders-ios/Marauders/Data/API/RetryingHTTPClient.swift` edit and the two session-core docs stay untouched and uncommitted. Nothing is committed or pushed without the owner's order.
- Docs keep each file's language: Thai in `deployment/README.md`, `docs/ci-cd.md` and `README.md`; English in `ARCHITECTURE.md` and the ADR.

## Review Focus

Failure modes the spec implies that no task would test unless named here; each gets its test in the task named.

1. A hand-typed `npx wrangler deploy` or `wrangler dev` with no `--env` still targets production and only warns. Nothing can stop it, so no script or `package.json` entry may produce one. Test: Task 6 scans for direct `wrangler` use.
2. A secret reaching output: Node's `Invalid URL` error carries the input string, and a vars file may hold quotes, CRLF, `export `, comments, or `=` inside a value. Tests: Task 1.
3. Migration surprises: a new file numbered below one already recorded (two branches), a recorded file edited later, a file that fails halfway, a production database with no tracking table yet. Tests: Task 2.
4. Wrong argv or a wrong version: production passes `--env ""` as an empty argument (not a dropped one), an untracked new file in `backend/` makes the tree dirty, and the previous version id is read before the deploy. Tests: Task 4.
5. A guard that fails open: the Release check with an unreadable Info.plist or table, `npm run dev` without `.dev.vars.staging`, a production script run with no terminal and no `--confirm`. Tests: Tasks 1, 4 and 10.

## Run conventions

- `REPO=/Users/tiscomacnb2486/Desktop/Marauders`. Use absolute paths in every command (the shell's working directory drifts between calls). Backend commands are `cd $REPO/backend && …` in one command.
- Work happens in the main checkout, uncommitted, touching only the paths each task lists. Xcode builds and tests run from a mirror in the session scratchpad (`SCRATCH` = that directory; it does not survive a reboot):

```bash
rsync -a --delete --exclude .git --exclude node_modules --exclude .claude --exclude .superpowers --exclude build/ --exclude vendor/ "$REPO/" "$SCRATCH/repo/"
xcodebuild test -project "$SCRATCH/repo/Marauders-ios/Marauders.xcodeproj" -scheme Marauders \
  -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' \
  -derivedDataPath "$SCRATCH/DerivedData" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" \
  -IDEBuildingContinueBuildingAfterErrors=YES -only-testing:MaraudersTests/<Suite>
```

  Re-sync before every Xcode command. Read the `Test run with N tests` line: N must be above 0 (a filter that matches nothing still prints `** TEST SUCCEEDED **`). Write each `-only-testing:` argument out; do not keep them in one shell variable.
- **Checkpoint step** (last step of every task): `git -C $REPO status --short` lists only this task's paths plus the owner's untouched `RetryingHTTPClient.swift` and the untracked docs. No commit; the commit grouping is at the end of this plan.

## File map

| File | Responsibility |
|---|---|
| `backend/environments.json` | the one table of environments, read by Node scripts and by the Release guard |
| `backend/scripts/lib/targets.mjs` | `--env` parsing, vars loading, banner, confirmation, `UsageError` |
| `backend/scripts/lib/migrations.mjs` | list, hash, plan and apply tracked migrations |
| `backend/scripts/lib/deploy.mjs` | the testable parts of `deploy` and `dev` |
| `backend/scripts/lib/r2.mjs` | the only place that builds a `wrangler r2 object` command |
| `backend/scripts/{migrate,deploy,dev,purge-videos,hls-transcode-r2,test-upload}.mjs` | the CLIs |
| `backend/src/health.ts` | the `/health` body |
| `backend/test/scripts/*.test.mjs` | `node:test` tests of the above, of the iOS agreement and of the workflow |
| `Marauders-ios/Scripts/check-release-config.sh` and its test | the Release guard |
| `.github/workflows/backend.yml` | CI |

---

### Task 1: The environment table and the shared script helper

**Files:**
- Create: `backend/environments.json`
- Create: `backend/scripts/lib/targets.mjs`
- Test: `backend/test/scripts/targets.test.mjs`
- Modify: `backend/package.json` (add script `"test:scripts": "node --test test/scripts/*.test.mjs"`)

**Interfaces:**
- Produces `environments.json`: `{ staging: EnvironmentConfig, production: EnvironmentConfig }` where `EnvironmentConfig = { wranglerEnv: string, worker: string, url: string, bucket: string, varsFile: string, devLogin: boolean, rateLimitNamespace: string, confirm: { write: string | null, purge: string } }`.
- Produces `targets.mjs`: `class UsageError extends Error`; `BACKEND_DIR: string`; `loadEnvironments(): Record<"staging"|"production", EnvironmentConfig>`; `parseCli(argv: string[], options?: ParseArgsOptions): { name: "staging"|"production", config: EnvironmentConfig, values: Record<string, string | boolean | string[] | undefined>, positionals: string[] }` (uses `node:util` `parseArgs`; `--env` and `--confirm` are always accepted; an unknown flag, a missing or an unknown `--env` throws `UsageError` naming the allowed values `staging, production`); `loadVars(config, backendDir?: string): Record<string, string>` (reads exactly `config.varsFile`, throws `UsageError` naming that file when it is missing, never reads a plain `.dev.vars`); `describeDatabase(databaseUrl: string): { host: string, database: string }`; `banner(input: { name, config, action: string, databaseUrl?: string }): string`; `confirm(input: { phrase: string | null, flag?: string, isTTY: boolean, ask: (prompt: string) => Promise<string> }): Promise<void>`.

- [ ] **Step 1: Write the failing tests** in `targets.test.mjs`:
  - `the table holds staging and production with every field`: each entry has exactly the eight keys; `url` matches `/^https:\/\/[a-z0-9-]+\.js6ctz7gtj\.workers\.dev$/`; production is `{worker: "marauders-api", bucket: "marauders-videos", wranglerEnv: "", rateLimitNamespace: "1001", devLogin: false, confirm: {write: "production", purge: "purge production"}}`; staging is `{worker: "marauders-api-staging", bucket: "marauders-videos-staging", wranglerEnv: "staging", rateLimitNamespace: "1002", devLogin: true, confirm: {write: null, purge: "purge staging"}}`; no two environments share `url`, `worker`, `bucket`, `varsFile` or `rateLimitNamespace`.
  - `plutil reads the production URL` (skipped unless `process.platform === "darwin"`): `plutil -extract production.url raw -o - environments.json` prints production's URL (the Release guard depends on this).
  - `parseCli`: `[]` throws `UsageError` whose message has `--env` and `staging, production`; `["--env","qa"]` throws mentioning `qa`; `["--env","staging"]` and `["--env=staging"]` give `name === "staging"`; `["--env","production","--confirm","production","--dry-run"]` with `{"dry-run": {type: "boolean"}}` gives `values.confirm === "production"` and `values["dry-run"] === true`; an unknown flag throws `UsageError`.
  - `loadVars reads only the environment's own file`: a temp dir holding a plain `.dev.vars` (`DATABASE_URL=plain-secret`) and no `.dev.vars.staging` throws `UsageError` naming `.dev.vars.staging` whose message lacks `plain-secret`; a file with `#` comments, blank lines, CRLF endings, `export A=1`, `B="two words"`, `C='x'` and `D=a=b==` returns `{A: "1", B: "two words", C: "x", D: "a=b=="}`.
  - `describeDatabase hides credentials`: `postgres://alice:s3cret@ep-x-pooler.eu-west-2.aws.neon.tech/neondb?sslmode=require` returns `{host: "ep-x-pooler.eu-west-2.aws.neon.tech", database: "neondb"}`; `"not a url s3cret"` throws `UsageError`, and neither `error.message`, `JSON.stringify(error)` nor `util.inspect(error)` contains `s3cret`.
  - `banner names the target and no secret`: contains the name, `config.worker`, `config.url`, `config.bucket`, the action, the database host and name, and not `s3cret`.
  - `confirm`: `phrase: null` resolves and never asks; `phrase: "production", flag: "production", isTTY: false` resolves; flag `"yes"` rejects; no flag with `isTTY: false` rejects with a message containing `--confirm "production"`; `isTTY: true` asks once (the prompt contains `production`), accepts `" production\n"` and rejects `"Production"`.
- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/targets.test.mjs` — Expected: FAIL (`ERR_MODULE_NOT_FOUND` for `targets.mjs`).
- [ ] **Step 3: Create `backend/environments.json`** with exactly:

```json
{
  "staging": {
    "wranglerEnv": "staging",
    "worker": "marauders-api-staging",
    "url": "https://marauders-api-staging.js6ctz7gtj.workers.dev",
    "bucket": "marauders-videos-staging",
    "varsFile": ".dev.vars.staging",
    "devLogin": true,
    "rateLimitNamespace": "1002",
    "confirm": { "write": null, "purge": "purge staging" }
  },
  "production": {
    "wranglerEnv": "",
    "worker": "marauders-api",
    "url": "https://marauders-api.js6ctz7gtj.workers.dev",
    "bucket": "marauders-videos",
    "varsFile": ".dev.vars.production",
    "devLogin": false,
    "rateLimitNamespace": "1001",
    "confirm": { "write": "production", "purge": "purge production" }
  }
}
```

- [ ] **Step 4: Implement `targets.mjs`** with the signatures above. Vars lines are `KEY=VALUE` with an optional `export ` prefix and optional single or double quotes; `#` lines and blank lines are skipped; CRLF is tolerated. `describeDatabase` catches the `URL` constructor's error and throws `UsageError("DATABASE_URL is not a valid URL")` without the input.
- [ ] **Step 5: Add `test:scripts` to `package.json`; run `cd $REPO/backend && npm run test:scripts`** — Expected: exit 0, `fail 0`.
- [ ] **Step 6: Checkpoint.**

---

### Task 2: Tracked migrations (`db:migrate --env`)

**Files:**
- Create: `backend/scripts/lib/migrations.mjs`
- Modify (rewrite): `backend/scripts/migrate.mjs`
- Test: `backend/test/scripts/migrations.test.mjs`

**Interfaces:**
- Consumes: `parseCli`, `loadVars`, `banner`, `confirm`, `describeDatabase`, `UsageError` from `targets.mjs`.
- Produces `migrations.mjs`: `NEVER_MIGRATED = ["004_purge_feed_videos.sql"]`; `listMigrationFiles(sqlDir: string): Promise<{ name: string, sha256: string, text: string }[]>` (names matching `/^\d{3}_.+\.sql$/` in numeric order, `NEVER_MIGRATED` excluded); `statementsFromSql(sqlText: string): string[]` (the current algorithm moved unchanged: split on `;`, strip `--` comments, trim, drop empties); `planMigrations(local: {name, sha256}[], recorded: {name, sha256}[]): { pending: string[], changed: string[], unknown: string[], outOfOrder: string[] }` (`outOfOrder` = pending names numbered below the highest recorded number); `type LocalFile = { name: string, sha256: string, text: string }` (the element `listMigrationFiles` returns); `runMigrations(input: { query: (text: string, values?: unknown[]) => Promise<{ rows: Record<string, unknown>[] }>, files: LocalFile[], dryRun: boolean, acceptChanged: string[], log: (line: string) => void }): Promise<{ applied: string[], pending: string[] }>`.
- CLI: `node scripts/migrate.mjs --env <staging|production> [--dry-run] [--accept-changed <file>]… [--confirm "<phrase>"]`.

Behaviour `runMigrations` must have: unless `dryRun`, first `CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`; recorded files come from `SELECT name, sha256 FROM schema_migrations`; a dry run never creates the table and treats a missing table (for example `SELECT to_regclass('public.schema_migrations')` is null) as nothing recorded; a changed, non-accepted file throws `UsageError` naming the file and `--accept-changed <name>`; a file is recorded (`INSERT … ON CONFLICT (name) DO UPDATE SET sha256 = EXCLUDED.sha256, applied_at = now()`) only after all its statements ran; an accepted changed file is re-applied and its hash updated. The CLI shows the plan first (a dry run through `runMigrations`), then calls `confirm(config.confirm.write)` (not for `--dry-run`), then applies. The first run on production lists every file as pending and says the files are re-runnable.

- [ ] **Step 1: Write the failing tests** in `migrations.test.mjs` (a fake `query` records every call):
  - `lists the 22 real files in numeric order and never 004`: names equal `001_schema.sql, 002_seed.sql, 003_remove_google_seeds.sql, 005_feed_video_coordinates.sql … 023_feed_video_upload_key.sql` (22 names, read from `backend/sql`).
  - `splits statements as the old script did`: statement counts per real file in order are `3,0,1,6,4,3,1,5,2,6,1,1,3,1,1,2,2,2,1,2,3,2` (total 52, measured 2026-11-19 with the old inline algorithm); none of the statements contains `--`.
  - `sha256 is hex of the file text` (64 hex characters, stable).
  - `plans pending, changed, unknown and out-of-order files`: local `001,002,003`, recorded `001,003` gives `pending ["002…"]` and `outOfOrder ["002…"]`; a recorded name with a different hash is in `changed`; a recorded name with no local file is in `unknown`.
  - `a fresh database creates the table, applies every file in order and records each one after its statements`: the first write is the `CREATE TABLE IF NOT EXISTS schema_migrations`; for each file its statements precede its `INSERT INTO schema_migrations`.
  - `a failure inside a file leaves that file unrecorded and stops`: the fake throws on the second statement of file B; the call rejects; the inserts hold A only.
  - `a second run applies nothing` (the fake returns the recorded rows).
  - `a changed file stops the run unless accepted`: the error message contains the file name and `--accept-changed`; with `acceptChanged: [name]` its statements run again and the stored hash is updated.
  - `a dry run writes nothing`: only `SELECT` queries; with no table every file is `pending` and no `CREATE TABLE` was sent.
  - `recorded names with no local file are logged, not fatal`.
- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/migrations.test.mjs` — Expected: FAIL (module not found).
- [ ] **Step 3: Implement `migrations.mjs`** (signatures above) and **rewrite `migrate.mjs`** to use it: `new Pool({ connectionString })` with `neonConfig.webSocketConstructor = ws` as the old script did, `pool.query` as `query`, `pool.end()` in `finally`, errors through `UsageError` print their message without a stack. The hard-coded file array and `loadDatabaseUrl` are deleted.
- [ ] **Step 4: Run** `cd $REPO/backend && node --test test/scripts/migrations.test.mjs` — Expected: exit 0, `fail 0`.
- [ ] **Step 5: Run the CLI without a target** `cd $REPO/backend && node scripts/migrate.mjs; echo "exit=$?"` — Expected: a `--env` usage message and `exit=2` or another non-zero code, no network access.
- [ ] **Step 6: Checkpoint.**

---

### Task 3: `/health` with environment and version, `[env.staging]`, binding parity

**Files:**
- Create: `backend/src/health.ts`
- Modify: `backend/src/index.ts` (the `Env` interface at line 28; the `/health` branch at line 154)
- Modify: `backend/wrangler.toml`
- Create: `backend/test/health.test.ts`, `backend/scripts/test-health.mjs`
- Create: `backend/test/scripts/parity.test.mjs`
- Modify: `backend/package.json` (add `"test:health": "node scripts/test-health.mjs"`)

**Interfaces:**
- Produces: `healthBody(env: { ENVIRONMENT?: string; GIT_SHA?: string }): { status: "ok"; environment: string; version: string }` — `environment` is `env.ENVIRONMENT ?? "unknown"`, `version` is `env.GIT_SHA ?? "dev"`.
- `Env` gains `ENVIRONMENT: string` and `GIT_SHA?: string`. `/health` answers `jsonResponse(healthBody(env))` through the existing `withCors`.

- [ ] **Step 1: Write the failing tests.**
  - `health.test.ts` (node:test; `scripts/test-health.mjs` has the shape of `scripts/test-upload-idempotency.mjs`: esbuild bundle with the fake `@neondatabase/serverless`, then `node --test`): `GET /health answers environment and version` through `worker.fetch(new Request("https://api.test/health"), env)` with `ENVIRONMENT: "staging"` (and again with `"production"`) and `GIT_SHA: "1d02680"` gives status 200 and a JSON body deep-equal to `{status: "ok", environment: "staging", version: "1d02680"}`; `unset values read unknown and dev`; `the body holds nothing else`: an env that also carries `DATABASE_URL: "postgres://u:pw@h/db"` and `JWT_SIGNING_SECRET` gives a body text containing neither `pw` nor the secret; `health needs no database`: the fake's `queries` is empty afterwards.
  - `parity.test.mjs`: `parseBindings reads wrangler's table` — a captured dry-run output fixture (header `Binding   Resource`, rows like `env.VIDEOS (marauders-videos-staging)   R2 Bucket`, `env.RATE_LIMITER (120 requests/60s)   Rate Limit`, `env.ENVIRONMENT ("staging")   Environment Variable`) yields `[{binding, detail, type}]`; then for each environment in `environments.json` it runs `npx wrangler deploy --dry-run --env <wranglerEnv> --outdir <tmp>` (production passes `--env` with an empty-string argument) with `WRANGLER_SEND_METRICS=false CI=true` and asserts: exit 0; the output does not contain `exists at the top level, but not on`; the binding names are exactly `VIDEOS, RATE_LIMITER, AUTH_RATE_LIMITER, ENVIRONMENT`; the `VIDEOS` detail equals `config.bucket`; the `ENVIRONMENT` detail contains `"<name>"`.
- [ ] **Step 2: Run to verify they fail.** `cd $REPO/backend && npm run test:health` — Expected: FAIL (`/health` still answers `{"status":"ok"}`). `node --test test/scripts/parity.test.mjs` — Expected: FAIL (no `ENVIRONMENT` binding).
- [ ] **Step 3: Implement.** Create `health.ts`; edit `index.ts` (the `Env` fields and the `/health` branch). In `wrangler.toml` add, after the secrets comments and before the existing `[[r2_buckets]]`, the table `[vars]` with `ENVIRONMENT = "production"`; then append exactly:

```toml
# Staging. A wrangler environment inherits no bindings, vars or observability, so everything the top level has is
# repeated here (test/scripts/parity.test.mjs fails when it is not). Production is the top level above.
[env.staging]

[env.staging.vars]
ENVIRONMENT = "staging"

[env.staging.observability]
enabled = true

[[env.staging.r2_buckets]]
binding = "VIDEOS"
bucket_name = "marauders-videos-staging"

[[env.staging.ratelimits]]
name = "RATE_LIMITER"
namespace_id = "1002"
[env.staging.ratelimits.simple]
limit = 120
period = 60

[[env.staging.ratelimits]]
name = "AUTH_RATE_LIMITER"
namespace_id = "1002"
[env.staging.ratelimits.simple]
limit = 30
period = 60
```

- [ ] **Step 4: Run** `cd $REPO/backend && npm run typecheck && npm run test:health && node --test test/scripts/parity.test.mjs` — Expected: all exit 0 (`fail 0`).
- [ ] **Step 5: Prove CI will pass the parity test without a Cloudflare login**: `cd $REPO/backend && env -i PATH="$PATH" HOME="$(mktemp -d)" CI=true node --test test/scripts/parity.test.mjs` — Expected: exit 0 (a dry run needs no credentials; checked 2026-11-19 on a scratch copy of this config).
- [ ] **Step 6: Checkpoint.**

---

### Task 4: The guarded `deploy`, the `dev` guard and the `test` aggregate

**Files:**
- Create: `backend/scripts/lib/deploy.mjs`, `backend/scripts/deploy.mjs`, `backend/scripts/dev.mjs`
- Test: `backend/test/scripts/deploy.test.mjs`
- Modify: `backend/package.json`

**Interfaces:**
- Consumes: `parseCli`, `loadVars`, `banner`, `confirm`, `UsageError` (Task 1); `listMigrationFiles`, `runMigrations` (Task 2).
- Produces `deploy.mjs` lib: `versionLabel(shortSha: string, dirtyBackend: boolean): string` (`"1d02680"` or `"1d02680-dirty"`); `wranglerDeployArgs(config: EnvironmentConfig, version: string): string[]` (`["deploy", "--env", config.wranglerEnv, "--var", "GIT_SHA:" + version]`; production's `--env` value is the empty string); `assertDeployable(name: string, dirtyBackend: boolean): void` (production with a dirty tree throws `UsageError`); `isDirty(porcelain: string): boolean` (true for any non-empty `git status --porcelain` text, an untracked `?? backend/x.mjs` line included); `checkHealth(input: { url: string, expectedEnvironment: string, expectedVersion: string, fetchFn: typeof fetch, attempts: number, delayMs: number, sleep: (ms: number) => Promise<void> }): Promise<{ ok: true } | { ok: false, reason: string }>`; `rollbackHint(name: string, config: EnvironmentConfig, previousVersionId: string | null): string`; `runDeploy(input: { name, config, git: { shortSha(): Promise<string>, dirtyBackend(): Promise<boolean> }, steps: { runTests(): Promise<void>, previousVersionId(): Promise<string | null>, migrate(): Promise<void>, wranglerDeploy(args: string[]): Promise<void> }, confirm: (phrase: string | null) => Promise<void>, fetchFn: typeof fetch, log: (line: string) => void }): Promise<void>`; `assertStagingVars(backendDir: string): void` (throws `UsageError` naming `.dev.vars.staging` when it is missing).
- Order inside `runDeploy`: banner → `assertDeployable` → `runTests` → `confirm(config.confirm.write)` → `previousVersionId` → `migrate` → `wranglerDeploy` → `checkHealth` → `rollbackHint`. No automatic rollback exists anywhere.
- CLI wiring in `deploy.mjs`: short sha from `git rev-parse --short=7 HEAD`; dirty is `isDirty(<output of git status --porcelain -- backend>)`; `runTests` runs `npm test`; `migrate` plans and applies with `runMigrations` (the confirmation was already given); `wranglerDeploy` runs `npx wrangler <args>`; the previous version id comes from `npx wrangler deployments list --json` (the executor inspects the real JSON shape; with no id the hint says to run `npx wrangler deployments list`).
- `package.json` scripts: `"dev": "node scripts/dev.mjs"` (asserts the staging vars file, then runs `wrangler dev --env staging`), `"deploy": "node scripts/deploy.mjs"` (no `--env` therefore prints usage and exits non-zero), `"deploy:staging": "node scripts/deploy.mjs --env staging"`, `"deploy:production": "node scripts/deploy.mjs --env production"`, and `"test": "npm run typecheck && npm run test:scripts && npm run test:health && npm run test:feed && npm run test:dubbed-audio && npm run test:dev-auth && npm run test:comments && npm run test:likes && npm run test:follows && npm run test:auth-refresh && npm run test:upload-idempotency"`.

- [ ] **Step 1: Write the failing tests** in `deploy.test.mjs`:
  - `versionLabel marks a dirty tree`.
  - `isDirty counts an untracked new file`: `"?? backend/scripts/new.mjs\n"` and `" M backend/src/index.ts\n"` are dirty, `""` is clean.
  - `wranglerDeployArgs`: staging deep-equals `["deploy","--env","staging","--var","GIT_SHA:abc1234"]`; production deep-equals `["deploy","--env","","--var","GIT_SHA:abc1234"]` (the empty string is an argument).
  - `production refuses a dirty backend before anything runs`: no step spy was called, not even `runTests`.
  - `staging deploys a dirty tree and labels the version -dirty` (the `--var` carries `…-dirty`; the health check expects the same label).
  - `the steps run in order`: the recorded calls for production are `tests, confirm, previous, migrate, deploy, health`; the same list for staging with `confirm` called with `null`.
  - `failing tests stop the run` (no confirm, no migrate, no deploy); `a refused confirmation stops before migrate`; `a failing migration stops before deploy`.
  - `a health answer for another environment or version fails the run and rolls nothing back`: `wranglerDeploy` was called once and no second deploy call exists.
  - `checkHealth retries while the old version still answers`: two stale answers then the expected one gives `ok`; with `attempts` exhausted it gives `{ok: false}` and the reason names expected and actual.
  - `rollbackHint` names the previous version id and `wrangler rollback`, or says to run `npx wrangler deployments list` when the id is null.
  - `dev refuses without .dev.vars.staging`: a temp dir holding only a plain `.dev.vars` throws `UsageError` naming `.dev.vars.staging`.
  - `bare deploy never deploys`: `package.json`'s `deploy` script is exactly `node scripts/deploy.mjs` and `parseCli([])` throws.
- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/deploy.test.mjs` — Expected: FAIL (module not found).
- [ ] **Step 3: Implement** `lib/deploy.mjs`, `deploy.mjs` and `dev.mjs` as above, and edit `package.json`.
- [ ] **Step 4: Run** `cd $REPO/backend && node --test test/scripts/deploy.test.mjs && node scripts/deploy.mjs; echo "exit=$?"` — Expected: tests pass; the bare command prints usage naming `--env` and exits non-zero without touching the network.
- [ ] **Step 5: Run the whole aggregate** `cd $REPO/backend && npm test` — Expected: exit 0 (typecheck, `test:scripts` and the eight existing offline tests).
- [ ] **Step 6: Checkpoint.**

---

### Task 5: `db:purge`, `video:hls` and `test-upload` take `--env`, and every R2 call is remote

**Files:**
- Create: `backend/scripts/lib/r2.mjs`
- Modify: `backend/scripts/purge-videos.mjs`, `backend/scripts/hls-transcode-r2.mjs`, `backend/scripts/test-upload.mjs`
- Test: `backend/test/scripts/r2.test.mjs`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces `r2.mjs`: `r2ObjectArgs(action: "put" | "delete", bucket: string, key: string, extra?: string[]): string[]` (returns `["wrangler","r2","object", action, bucket + "/" + key, ...extra, "--remote"]`); `mediaKeyFromStreamUrl(streamUrl: string): string | null` and `keysToDeleteForRow(streamUrl: string): string[]` (moved unchanged from `purge-videos.mjs`); `masterStreamUrl(config: EnvironmentConfig, r2Prefix: string): string` (`config.url + "/v1/media/" + r2Prefix + "/master.m3u8"`).
- Behaviour: `purge-videos.mjs --env <e> [--confirm "<phrase>"]` prints the banner, the row count and the number of objects it will try, calls `confirm(config.confirm.purge)` **before** deleting anything, then deletes objects through `r2ObjectArgs("delete", config.bucket, key)` and rows; the `DATABASE_URL` environment-variable fallback is removed (the database comes only from the environment's vars file). `hls-transcode-r2.mjs --env <e> <feed_videos.id> [local-source.mp4] [--confirm "<phrase>"]` takes the bucket and the new `stream_url` from the table, confirms `config.confirm.write`, uploads through `r2ObjectArgs("put", …, ["--file", path])`; the worker-origin argument and `MARAUDERS_API_ORIGIN` are dropped. `test-upload.mjs` takes `--env` (default `staging`; production confirms `config.confirm.write`) and posts to `config.url + "/v1/videos"`. Header comments no longer mention `.dev.vars`. Known cost, put in the purge script's header: an HLS clip tries up to 201 remote deletes.

- [ ] **Step 1: Write the failing tests** in `r2.test.mjs`: `every r2 command ends with --remote` (put and delete, with and without `extra`; deep-equal `["wrangler","r2","object","delete","marauders-videos-staging/videos/x/seg000.ts","--remote"]` and `["wrangler","r2","object","put","marauders-videos/videos/x/master.m3u8","--file","/tmp/a","--remote"]`); `keysToDeleteForRow`: an MP4 URL gives `["videos/<uuid>.mp4"]`, an HLS master URL gives the master plus `seg000.ts … seg199.ts` (201 keys), a URL outside `/v1/media/` gives `[]`; `masterStreamUrl uses the environment's own URL` for both environments.
- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/r2.test.mjs` — Expected: FAIL (module not found).
- [ ] **Step 3: Implement** `r2.mjs` and convert the three scripts as described.
- [ ] **Step 4: Run** `cd $REPO/backend && node --test test/scripts/r2.test.mjs`, then `for s in purge-videos hls-transcode-r2 test-upload; do node scripts/$s.mjs --env qa 2>&1 | head -2; done` — Expected: tests pass; each script rejects the unknown environment with a usage message (the last one does not post anything).
- [ ] **Step 5: Checkpoint.**

---

### Task 6: Retire the plain `.dev.vars` in the tooling, and scan for hard-coded targets

**Files:**
- Modify: `.gitignore` (replace the line `backend/.dev.vars` with `backend/.dev.vars*` and `!backend/.dev.vars.example`)
- Rename: `backend/.env.example` to `backend/.dev.vars.example` (`git mv`), content: a header comment (copy to `.dev.vars.staging` or `.dev.vars.production`; never commit values) and the four names `DATABASE_URL=`, `JWT_SIGNING_SECRET=`, `APPLE_CLIENT_ID=`, `DEV_LOGIN_SECRET=` with empty values
- Test: `backend/test/scripts/noHardcodedTargets.test.mjs`

- [ ] **Step 1: Write the failing tests:**
  - `no script names a host, a bucket or the plain vars file`: read every `backend/scripts/**/*.mjs`; none contains `workers.dev`, any `bucket` or `url` value from `environments.json`, or matches `/\.dev\.vars(?![.\w])/` (`.dev.vars.staging` in a message is fine; the plain name is not).
  - `no package.json script calls wrangler directly` (the word `wrangler` appears in no script value).
  - `every .dev.vars file is ignored but the example`: `.gitignore` has the lines `backend/.dev.vars*` and `!backend/.dev.vars.example`; and, when the test runs inside a git work tree (it skips itself in a copy without `.git`), `git check-ignore -q` exits 0 for `backend/.dev.vars`, `backend/.dev.vars.staging` and `backend/.dev.vars.production`, and 1 for `backend/.dev.vars.example`.
  - `the example lists exactly the four names with empty values`.
- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/noHardcodedTargets.test.mjs` — Expected: FAIL (ignore rules and example missing).
- [ ] **Step 3: Apply the `.gitignore` edit and the rename.** Do **not** delete the owner's local `backend/.dev.vars` here; it is removed in the rollout after the split.
- [ ] **Step 4: Run** `cd $REPO/backend && npm test` — Expected: exit 0.
- [ ] **Step 5: Checkpoint** (the rename shows as `R` in `git status`).

---

### Task 7: The app's URL travels through Info.plist (proof by builds)

**Files:**
- Modify: `Marauders-ios/Marauders.xcodeproj/project.pbxproj` (the app target's Debug configuration line 467 and Release configuration line 512)
- Modify: `Marauders-ios/Config/Info-Additions.plist`

No behaviour changes in this task: `APIConfiguration` still reads the bundled plist first, so the app keeps talking to production until Task 8.

- [ ] **Step 1: Edit the project.** In both configurations of the app target delete the line `INFOPLIST_KEY_MARAUDERS_API_BASE_URL = "https://marauders-api.js6ctz7gtj.workers.dev";` and add, in sorted position (after `LD_RUNPATH_SEARCH_PATHS`, before `MARKETING_VERSION`, so Xcode does not reorder it later), `MARAUDERS_API_BASE_URL = "https://marauders-api-staging.js6ctz7gtj.workers.dev";` in Debug and `MARAUDERS_API_BASE_URL = "https://marauders-api.js6ctz7gtj.workers.dev";` in Release. In `Info-Additions.plist` add the key `MARAUDERS_API_BASE_URL` with the string `$(MARAUDERS_API_BASE_URL)` and drop the comment's claim that it holds only keys without a build setting if it no longer fits.
- [ ] **Step 2: Build Debug from the mirror and read the key.** Sync the mirror, then `xcodebuild build -project "$SCRATCH/repo/Marauders-ios/Marauders.xcodeproj" -scheme Marauders -configuration Debug -destination 'platform=iOS Simulator,id=902C645A-22D9-47F3-86B0-3E4623B6B2A9' -derivedDataPath "$SCRATCH/DerivedData" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages"`, then `plutil -extract MARAUDERS_API_BASE_URL raw -o - "$SCRATCH/DerivedData/Build/Products/Debug-iphonesimulator/Marauders.app/Info.plist"` — Expected: `https://marauders-api-staging.js6ctz7gtj.workers.dev`.
- [ ] **Step 3: Archive Release unsigned, the way Jenkins builds it, and read the key.** `xcodebuild archive -project "$SCRATCH/repo/Marauders-ios/Marauders.xcodeproj" -scheme Marauders -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/DerivedData-release" -clonedSourcePackagesDirPath "$SCRATCH/SourcePackages" -archivePath "$SCRATCH/Marauders.xcarchive" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` (about 40 s warm; delete an older `Marauders.xcarchive` first), then `plutil -extract MARAUDERS_API_BASE_URL raw -o - "$SCRATCH/Marauders.xcarchive/Products/Applications/Marauders.app/Info.plist"` — Expected: `https://marauders-api.js6ctz7gtj.workers.dev`.
- [ ] **Step 4: If either key is missing or still reads `$(MARAUDERS_API_BASE_URL)`, stop.** The spec's fallback is a Run Script phase after Resources that writes the key with `/usr/libexec/PlistBuddy -c "Set :MARAUDERS_API_BASE_URL $MARAUDERS_API_BASE_URL"` on `$TARGET_BUILD_DIR/$INFOPLIST_PATH` (the plist then holds a placeholder value). Tell the owner before switching mechanism.
- [ ] **Step 5: Checkpoint.**

---

### Task 8: `APIConfiguration` reads Info.plist only, plus a Debug override; the bundled plist goes

**Files:**
- Modify: `Marauders-ios/Marauders/Data/API/APIConfiguration.swift` (`apiBaseURL` at line 19, `resolveBaseURLString` and `bundledConfigValue` at lines 223-245, the error text at line 255)
- Delete: `Marauders-ios/Marauders/APIConfiguration.plist`
- Modify: `Marauders-ios/Scripts/plain-strings-allowlist.txt` (line 15 carries the old error text)
- Test: `Marauders-ios/MaraudersTests/APIConfigurationTests.swift`
- Test: `backend/test/scripts/iosEnvironments.test.mjs`

**Interfaces:**
- Produces: `enum APIBaseURLSource: Equatable, Sendable { case configured, override }`; `struct APIBaseURL: Equatable, Sendable { let url: URL; let source: APIBaseURLSource }`; in `extension APIConfiguration`: `static func resolveBaseURL(configured: String?, override: String?) throws -> APIBaseURL` (pure; a non-empty `override` wins and is validated, an invalid one throws and never falls back; `configured` nil or empty with no override throws `.missingBaseURL`; validation is the existing rule: https, a host, no path beyond `/`, whitespace trimmed); `static func resolvedBaseURL() throws -> APIBaseURL` (reads `Bundle.main.object(forInfoDictionaryKey: "MARAUDERS_API_BASE_URL")` and, under `#if DEBUG` only, `ProcessInfo.processInfo.environment["MARAUDERS_API_BASE_URL"]` as the override; keeps the existing `api base host=` log line); `static func describe(_ base: APIBaseURL) -> String` (`"<host> (configured)"` or `"<host> (override)"`); `apiBaseURL() throws -> URL` keeps its signature and returns `resolvedBaseURL().url`.
- The `.missingBaseURL` text becomes `API URL not found — check the MARAUDERS_API_BASE_URL build setting`; allowlist line 15 changes with it.

- [ ] **Step 1: Write the failing tests.**
  - `APIConfigurationTests` (Swift Testing, `@MainActor struct`): `theConfiguredValueIsUsedWithoutAnOverride`; `anOverrideWinsAndIsMarkedAsOne`; `anEmptyOverrideCountsAsNone`; `anInvalidOverrideThrowsInsteadOfFallingBack` (override `http://b.example` throws `invalidBaseURL`); `onlyHttpsWithoutAPathIsAccepted` (arguments `http://a.example`, `https://a.example/v1`, `ftp://a.example`, `a.example`, `https://` throw `invalidBaseURL`; `https://a.example`, `https://a.example/` and `"  https://a.example\n"` resolve); `aMissingValueIsReported` (nil and `""` with no override throw `missingBaseURL`); `describeNamesHostAndSource`; `theDebugBuildReceivesStagingThroughInfoPlist` (when the process has no `MARAUDERS_API_BASE_URL` variable, `resolvedBaseURL()` has source `.configured` and host `marauders-api-staging.js6ctz7gtj.workers.dev`; this proves Task 7's plumbing in the unit run).
  - `iosEnvironments.test.mjs` (backend, `node:test`): parse `Marauders-ios/Marauders.xcodeproj/project.pbxproj` into `XCBuildConfiguration` blocks; the block named Debug that holds `PRODUCT_BUNDLE_IDENTIFIER = com.somsak.Marauders;` has `MARAUDERS_API_BASE_URL` equal to staging's table URL, the Release one equals production's; no `INFOPLIST_KEY_MARAUDERS_API_BASE_URL` remains; `Info-Additions.plist` maps `MARAUDERS_API_BASE_URL` to `$(MARAUDERS_API_BASE_URL)`; `Marauders-ios/Marauders/APIConfiguration.plist` does not exist.
- [ ] **Step 2: Run to verify they fail.** `cd $REPO/backend && node --test test/scripts/iosEnvironments.test.mjs` — Expected: FAIL (the plist still exists). The Swift suite does not compile yet (no `resolveBaseURL`).
- [ ] **Step 3: Implement** the interfaces above in `APIConfiguration.swift`; delete `bundledConfigValue`, `resolveBaseURLString` and `Marauders/APIConfiguration.plist`; update the error text and allowlist line 15. The app target is file-system-synchronized, so no project edit is needed.
- [ ] **Step 4: Run the unit target.** Sync the mirror, then the unit command with `-only-testing:MaraudersTests` (the whole target: about 5 s of test time once built, and eight of its files call `APIConfiguration`) — Expected: `** TEST SUCCEEDED **` and a `Test run with N tests` line with N at least 1334 (the count of the last full run) plus the new tests.
- [ ] **Step 5: Run the backend agreement test and the scans.** `cd $REPO/backend && node --test test/scripts/iosEnvironments.test.mjs`; `python3 $REPO/Marauders-ios/Scripts/find-plain-strings.py; echo "exit=$?"`; `sh $REPO/Marauders-ios/Scripts/check-layers.sh --strict; echo "exit=$?"` — Expected: all exit 0.
- [ ] **Step 6: Check no stale reference remains.** `grep -rn "APIConfiguration.plist" $REPO --include='*.swift' --include='*.pbxproj' --include='*.sh' --include='*.mjs' --exclude-dir=.git --exclude-dir=.claude --exclude-dir=node_modules` — Expected: no output (docs are Task 12).
- [ ] **Step 7: Checkpoint.**

---

### Task 9: Dev login follows the configured host, and the Debug log shows the host

**Files:**
- Modify: `Marauders-ios/Marauders/Shared/Configuration/DevLogin.swift`
- Modify: `Marauders-ios/Marauders/Presentation/Debug/DebugLogView.swift`
- Test: `Marauders-ios/MaraudersTests/DevLoginTests.swift` (all `#if DEBUG`)

**Interfaces:**
- Consumes: `APIBaseURLSource`, `APIConfiguration.resolvedBaseURL()`, `APIConfiguration.describe(_:)` (Task 8).
- Produces: `static func offeredSecret(_ secret: String?, source: APIBaseURLSource) -> String?` on `DevLogin` (pure; nil unless the secret is non-empty and the source is `.configured`). `DevLogin.secret` returns `offeredSecret(<today's lookup>, source: (try? APIConfiguration.resolvedBaseURL().source) ?? .override)`; `isAvailable` stays `secret != nil`. The Simulator lookup reads `backend/.dev.vars.staging` instead of `backend/.dev.vars`; the doc comments say so.
- `DebugLogView` shows `Text(verbatim: <describe(resolved) or "API URL unresolved">)` as the screen's subtitle (`.navigationSubtitle`), Debug only because the view is only reachable from the Debug `Log` tab.

- [ ] **Step 1: Write the failing tests** (`DevLoginTests`, Swift Testing): `aSecretIsOfferedAgainstTheConfiguredHost` (`offeredSecret("s", source: .configured) == "s"`); `noSecretIsOfferedAgainstAnOverride` (`.override` gives nil); `noSecretWithoutOne` (nil and `""` give nil).
- [ ] **Step 2: Run to verify it fails** (does not compile): the unit command with `-only-testing:MaraudersTests/DevLoginTests`.
- [ ] **Step 3: Implement** the rule, the new path and the subtitle. If `find-plain-strings.py` reports the new literal, add it to `plain-strings-allowlist.txt` with the reason `Debug-only caption`.
- [ ] **Step 4: Run** the whole unit target (`-only-testing:MaraudersTests`) — Expected: success with N at least the count after Task 8 plus the new tests; then `python3 $REPO/Marauders-ios/Scripts/find-plain-strings.py` and `sh $REPO/Marauders-ios/Scripts/check-layers.sh --strict` exit 0.
- [ ] **Step 5: Look at the screen.** Build and launch the Debug app on the simulator from the mirror (simulator tool: attach, launch, open the `Log` tab, screenshot) — Expected: the subtitle reads `marauders-api-staging.js6ctz7gtj.workers.dev (configured)`.
- [ ] **Step 6: Checkpoint.**

---

### Task 10: The Release guard

**Files:**
- Create: `Marauders-ios/Scripts/check-release-config.sh`
- Test: `Marauders-ios/Scripts/tests/check-release-config-tests.sh`
- Modify: `Marauders-ios/Marauders.xcodeproj/project.pbxproj` (a new `PBXShellScriptBuildPhase`, and its id appended last in the app target's `buildPhases` at line 115)

**Interfaces:**
- `sh Scripts/check-release-config.sh --info-plist <built Info.plist> --environments <environments.json> --bundle <Marauders.app>`: exit 0 and print `release config ok: <url>` only when the plist's `MARAUDERS_API_BASE_URL` equals `production.url` from the table (read with `plutil -extract production.url raw -o -`) **and** no `APIConfiguration.plist` is inside the bundle. Every failure prints one or more lines starting `error: ` (the form Xcode lists as a build error) and exits 1. It fails closed: an unreadable plist, an unreadable table or a missing key is a failure.
- The phase (id `7C3E91A0D5B44F28A1E6C0D9`, name `Run Script release config check`, `alwaysOutOfDate = 1`, `shellPath = /bin/sh`, `inputPaths = ("$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)")` so Xcode runs it after that file exists) has the script: skip unless `$CONFIGURATION` is `Release`, then run `sh "$SRCROOT/Scripts/check-release-config.sh" --info-plist "$TARGET_BUILD_DIR/$INFOPLIST_PATH" --environments "$SRCROOT/../backend/environments.json" --bundle "$TARGET_BUILD_DIR/$WRAPPER_NAME" 2>&1`. First check the id appears nowhere else in the project.

- [ ] **Step 1: Write the failing tests** (`check-release-config-tests.sh`, in the style of `check-layers-tests.sh`: `begin`, a fixture Info.plist and table written per case, `run`, `expect_text`, a final count and exit 1 on any failure): `passes with production's URL and no stray plist`; `fails when the URL is staging's`; `fails when the key is missing`; `fails when the key is the literal $(MARAUDERS_API_BASE_URL)`; `fails when APIConfiguration.plist is in the bundle`; `fails when the table cannot be read`; `fails when the Info.plist cannot be read`; `every failure starts with "error: " and exits 1`.
- [ ] **Step 2: Run to verify it fails.** `sh $REPO/Marauders-ios/Scripts/tests/check-release-config-tests.sh` — Expected: FAIL (script missing).
- [ ] **Step 3: Implement the script and add the phase** (object in the `PBXShellScriptBuildPhase` section after the layer-check object; id appended after `06BC2C283075A7FB0064F635 /* Resources */,`).
- [ ] **Step 4: Run** `sh $REPO/Marauders-ios/Scripts/tests/check-release-config-tests.sh` — Expected: `check-release-config: all N cases passed`.
- [ ] **Step 5: Prove the phase in real builds** (mirror synced; the unsigned archive of Task 7 step 3): it passes and the build log holds `release config ok: https://marauders-api.js6ctz7gtj.workers.dev`; the same archive with `MARAUDERS_API_BASE_URL=https://marauders-api-staging.js6ctz7gtj.workers.dev` added on the `xcodebuild` command line fails with an `error: ` line from the script; the Debug build of Task 7 step 2 still succeeds and does not run the check.
- [ ] **Step 6: Checkpoint.**

---

### Task 11: CI that runs the offline backend tests

**Files:**
- Create: `.github/workflows/backend.yml`
- Test: `backend/test/scripts/workflow.test.mjs`

**Workflow shape:** name `Backend`; triggers `push` (branch `main`), `pull_request` and `workflow_dispatch`, with `paths` limited to `backend/**`, `.github/workflows/backend.yml`, `Marauders-ios/Marauders.xcodeproj/project.pbxproj`, `Marauders-ios/Config/Info-Additions.plist` and `Marauders-ios/Marauders/APIConfiguration.plist` (the agreement test reads them, and a plist that comes back must trigger it); `permissions: contents: read`; `concurrency` group `backend-${{ github.ref }}` with `cancel-in-progress: true`; one job `test` on `ubuntu-latest`, `timeout-minutes: 15`, `defaults.run.working-directory: backend`; steps: `actions/checkout`, `actions/setup-node` (`node-version: 22`, `cache: npm`, `cache-dependency-path: backend/package-lock.json`), `npm ci`, `npm test`. Resolve each action's newest release tag and its full commit SHA with `gh api repos/actions/<name>/releases/latest --jq .tag_name` and `gh api repos/actions/<name>/commits/<tag> --jq .sha`; write `uses: actions/<name>@<40-hex> # <tag>`.

- [ ] **Step 1: Write the failing tests** (`workflow.test.mjs`, text checks, no YAML dependency): the file exists; it has `permissions:` with `contents: read`; it contains no `secrets.`, no `pull_request_target`, no `CLOUDFLARE`, no `DATABASE_URL`, no `wrangler deploy`; every `uses:` line matches `/uses: [\w.-]+\/[\w.-]+@[0-9a-f]{40}\b/`; it has `concurrency:`; its `paths` hold the five entries above; it runs `npm ci` and `npm test`.
- [ ] **Step 2: Run to verify it fails.** `cd $REPO/backend && node --test test/scripts/workflow.test.mjs` — Expected: FAIL (no workflow file).
- [ ] **Step 3: Write the workflow** with the resolved SHAs.
- [ ] **Step 4: Run** `cd $REPO/backend && npm test` — Expected: exit 0.
- [ ] **Step 5: Run it as CI would, in a clean copy with a scrubbed environment.** `rsync -a --delete --exclude .git --exclude node_modules --exclude .claude --exclude .superpowers --exclude '.dev.vars*' --exclude .wrangler --exclude build/ "$REPO/" "$SCRATCH/clean/"`, then `cd "$SCRATCH/clean/backend" && env -i PATH="$PATH" HOME="$(mktemp -d)" CI=true npm ci && env -i PATH="$PATH" HOME="$(mktemp -d)" CI=true npm test` — Expected: exit 0 with no `.dev.vars*` file present (only `npm ci` needs the network). `grep -c '@esbuild/linux-x64' $REPO/backend/package-lock.json` is 3, so a Linux runner installs the same bundler.
- [ ] **Step 6: Checkpoint.**

---

### Task 12: Docs

**Files:**
- Create: `docs/adr/010-environments.md` (English; status Accepted, date 2026-11-19; sections Context, Decision, Consequences, Triggers to revisit, Alternatives)
- Modify: `docs/adr/README.md` (a row for 010)
- Modify: `deployment/README.md` (Thai)
- Modify: `docs/ci-cd.md` (Thai)
- Modify: `README.md` (Thai)
- Modify: `ARCHITECTURE.md` (English)

Content that must be there: **ADR 010** — why one environment was a risk (the findings in the spec's first section), the decision (staging, the table, `--env` scripts, phrases, the iOS build setting and Release guard, tests-only CI), the A versus B trade with the public-repo and token reasoning, the costs (a phone that alternates a Debug-on-staging build and a TestFlight build signs in again; an empty staging feed; the startup cache may show up to two other-environment clips for a moment; absolute `stream_url`/`avatar_url` host-bound), the triggers to revisit (second developer, external TestFlight testers, manual deploys become a chore, a custom domain before the first public release). **`deployment/README.md`** — an environments table; every command with `--env`; the order (tests, migrate, deploy, `/health`); the tracking table and `--accept-changed`; secrets per environment (`wrangler secret bulk`); `.dev.vars.<env>` instead of `.dev.vars`; `npm run dev` runs staging; the iOS paragraph replaced by the build setting, the Debug override (`SIMCTL_CHILD_MARAUDERS_API_BASE_URL`) and the Release guard; rollback (`npx wrangler rollback <version-id>` with the environment) and "never run a bare `wrangler deploy`"; new migration files must be re-runnable and carry no `;` in comments; `/health` examples show environment and version. **`docs/ci-cd.md`** — the last section becomes "CI runs the offline tests, deploys stay guarded scripts"; the workflow, `npm test`, no secrets; no "last migration" number named. **`README.md`** — the three `.dev.vars` and dev-login lines (109, 138, 246) say staging and that production has no `DEV_LOGIN_SECRET`. **`ARCHITECTURE.md`** — the rows at lines 45, 99 and 686, the diagram text at line 87 and a short Environments section (table and rules).

- [ ] **Step 1: Write the ADR and add its row.**
- [ ] **Step 2: Update the four other files.**
- [ ] **Step 3: Check for stale text.** `grep -rn -E 'INFOPLIST_KEY_MARAUDERS|APIConfiguration\.plist|\.env\.example|backend/\.dev\.vars([^.]|$)' $REPO/README.md $REPO/ARCHITECTURE.md $REPO/deployment $REPO/docs/ci-cd.md $REPO/docs/adr` — Expected: only historical mentions inside ADR 010.
- [ ] **Step 4: Check every command the docs show against the real scripts** (`--env` spelling, `npm run` names) by reading `backend/package.json`.
- [ ] **Step 5: Checkpoint.**

---

### Task 13: Gate, then rollout (every cloud step waits for the owner's yes)

This task runs after Tasks 1 to 12 are done. **[ASK]** marks a step that needs the owner's yes in chat first.

> **Changed on 2026-11-20: the owner chose ONE backend (production).** Nothing is created for staging: steps 3 (from the clipboard on), 4, 5, 6, 7 and 9 below are **not done and not planned**; they are the recipe for provisioning staging later (also in `deployment/README.md`, "เมื่อจะสร้าง staging"). Step 3's local part is done, and `.dev.vars.production` also carries `DEV_LOGIN_SECRET` (the Simulator's dev login runs against production, so step 9's deletion is cancelled). Debug now talks to production (`backend/test/scripts/iosEnvironments.test.mjs`, `DEBUG_ENVIRONMENT`). Still to do, each with the owner's yes: step 8 (the three commits, then production: the first run of the deploy script has no staging rehearsal), step 10 (delete the plain `.dev.vars`), step 11 (push) and step 12 (memory). The rulings are in the ledger and in ADR 010's Amendment.

- [ ] **Step 1: Local gates.** `cd $REPO/backend && npm test`; the clean-copy run of Task 11 step 5; the whole unit target on the simulator from a fresh mirror (read `Test run with N tests`); the layer checker `--strict` and `find-plain-strings.py` clean; the UI target once (about 16 to 34 minutes; 51 of 52 with the known simulator-only red `testACommentInAnotherLanguageGivesThePageASwitchAndNoButtonOfItsOwn` is the baseline); the unsigned Release build passes the guard. Report numbers, not "green".
- [ ] **Step 2: Whole-diff review.** One fresh reviewer on the most capable model reads `git -C $REPO diff` and the new files against the spec; fix what it finds before any cloud step.
- [ ] **Step 3: [ASK] The owner creates the empty Neon database for staging** and puts its pooled connection string on the clipboard. First, locally and with no cloud call, split production's file: `cd $REPO/backend && umask 077 && grep '^DATABASE_URL=' .dev.vars > .dev.vars.production && grep -c '=' .dev.vars.production` (expect `1`): from then on reading `.dev.vars.staging` fails if it names the same server and database as `.dev.vars.production` (added after the whole-diff review; a wrong clipboard or a `cp` would otherwise make `--env staging` commands run on production's database). Then write the staging vars file without printing anything (prints only the line count, expected `4`): `cd $REPO/backend && umask 077 && { printf 'DATABASE_URL=%s\n' "$(pbpaste)"; printf 'JWT_SIGNING_SECRET=%s\n' "$(openssl rand -base64 48 | tr -d '\n')"; printf 'DEV_LOGIN_SECRET=%s\n' "$(openssl rand -base64 48 | tr -d '\n')"; printf 'APPLE_CLIENT_ID=%s\n' com.somsak.Marauders; } > .dev.vars.staging && grep -c '=' .dev.vars.staging`. Confirm the Neon plan allows the second database (the owner's console).
- [ ] **Step 4: [ASK] Create the bucket.** `cd $REPO/backend && npx wrangler r2 bucket create marauders-videos-staging`. Then, in the same yes, one harmless call to see how wrangler answers a delete of a key that is not there (the bucket is empty): `npx wrangler r2 object delete marauders-videos-staging/does-not-exist-check --remote`; save its exit code and stderr in the report. If it succeeds, a miss is no failure and nothing changes; if it fails, add that text as a fixture to `test/scripts/r2.test.mjs` and a classifier for exactly it (until then every refused delete keeps the purge's rows).
- [ ] **Step 5: [ASK] Migrate staging from empty, twice.** `npm run db:migrate -- --env staging --dry-run` (expect 22 pending), then `npm run db:migrate -- --env staging` (22 applied), then again (nothing pending). Fix what breaks; 001 to 023 on an empty database have never been run together since the first setup.
- [ ] **Step 6: [ASK] Deploy staging.** `npm run deploy:staging` — Expected: tests, nothing pending, deploy, the health check passes. Compare the URL wrangler prints with the table; if it differs, replace it everywhere at once (`grep -rn marauders-api-staging` lists the places: `backend/environments.json`, the Debug build-setting line of `Marauders.xcodeproj/project.pbxproj`, `MaraudersTests/APIBaseURLTests.swift`, `Scripts/tests/check-release-config-tests.sh`, `backend/test/scripts/targets.test.mjs` and `r2.test.mjs`, ADR 010, `ARCHITECTURE.md`, `deployment/README.md`, the spec and this plan) and run `npm test` and the unit target again. Before any secret exists, a POST to `/v1/auth/dev` with a made-up secret prints `404` (`curl -s -o /dev/null -w '%{http_code}\n' -X POST https://marauders-api-staging.js6ctz7gtj.workers.dev/v1/auth/dev -H 'content-type: application/json' --data '{"secret":"x","label":"y"}'`). Then set the secrets: check `npx wrangler secret bulk --help` accepts a dotenv file, then `npx wrangler secret bulk .dev.vars.staging --env staging` (if it does not, convert to a `0600` JSON file in the scratchpad, upload it, delete it). Checks: `curl -s https://marauders-api-staging.js6ctz7gtj.workers.dev/health` gives `environment: "staging"` and a version; `curl -s "https://marauders-api-staging.js6ctz7gtj.workers.dev/v1/feed?limit=5"` gives an empty `items`; a POST to `/v1/auth/dev` with the staging secret (read into a shell variable from the file, never printed) answers 200.
- [ ] **Step 7: The app against staging.** Debug build on the simulator: the Log subtitle says staging, sign in as the test user, upload one short clip through the app, see it in the staging feed. (Add a clip to the simulator with `xcrun simctl addmedia` if its library is empty.)
- [ ] **Step 8: [ASK] Commit, then production.** `deploy:production` refuses a `backend/` with uncommitted changes, and `backend/` holds files of all three commit groups below (`backend/test/scripts/iosEnvironments.test.mjs` tests the app and `workflow.test.mjs` the workflow, and `deploy` runs `npm test`), so a commit of group 1 alone is not enough: ask the owner once, before anything touches production, to order **all three commits** below (no push). Then (`.dev.vars.production` already exists from step 3) `npm run db:migrate -- --env production --dry-run` (expect all 22 pending and "no tracking table"), and after the owner's yes `npm run db:migrate -- --env production --confirm production`, then `npm run deploy:production -- --confirm production`. Checks: `/health` says `production` and a version; `/v1/feed?limit=1` answers 200; the printed rollback hint is saved in the report. Do **not** run `db:purge` on production in this rollout: the first purge after the `--remote` fix deletes real objects.
- [ ] **Step 9: [ASK, last; only after the app change is committed and the owner's Simulator has used staging] Remove production's dev login.** `cd $REPO/backend && npx wrangler secret list` must show `DEV_LOGIN_SECRET`; then `npx wrangler secret delete DEV_LOGIN_SECRET`; then `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://marauders-api.js6ctz7gtj.workers.dev/v1/auth/dev -H 'content-type: application/json' --data '{"secret":"x","label":"y"}'` must print `404`.
- [ ] **Step 10: [ASK] Delete the plain `backend/.dev.vars`** (it holds production's database URL and its dev-login secret; `.dev.vars.production` has the URL). A tool that still reads it must now fail loudly.
- [ ] **Step 11: Push only on the owner's order** (the three commits were made in step 8; the grouping is below). After the owner pushes, one `gh run list --workflow backend.yml --limit 1` shows the first run; report its result as it is.
- [ ] **Step 12: Update the memory notes** (`project-environments-assessment.md` and the index line) with what shipped, the deployed version ids and the rollback targets.

---

## Commit grouping (run only on the owner's order, all three before step 8's production deploy; each message ends with the `Co-Authored-By` trailer the session was given)

1. `Give the backend a staging environment and scripts that name their target`: Tasks 1 to 6 (`backend/**`, `.gitignore`).
2. `Point the app at staging in Debug and production in Release, and fail a Release build that does not`: Tasks 7 to 10 (`Marauders-ios/**`, `backend/test/scripts/iosEnvironments.test.mjs`).
3. `Run the backend tests on GitHub and write the environments down`: Tasks 11 and 12 (`.github/**`, docs).

Never stage the owner's `RetryingHTTPClient.swift` or the untracked session-core docs; the design and this plan are committed in commit 3 only if the owner says so.
