# Environments: design

Date: 2026-11-19. Status: **written after the owner chose option A ("ไม่ให้ (A)"); approved by the owner on 2026-11-19 ("อนุมัติ") with production logging left off (option 1, see Open for the owner); the builder check corrected two facts below; nothing is built.**
**Amended 2026-11-20: at the first cloud step the owner chose ONE backend, production.** Staging stays defined (the table, `[env.staging]`, the scripts, their tests) but nothing is created for it; Debug builds talk to production; production keeps its `DEV_LOGIN_SECRET`. Goals 1 and 9, section 4 (steps 2 to 4 and 6), section 5's "Debug builds talk to staging" and the staging checks of Verification are superseded by the Amendment in `docs/adr/010-environments.md`; the text below is kept as it was approved.

Size: a project (Worker config, five scripts, the app's configuration, one CI workflow, docs and one ADR; no new dependency in the app or in the Worker).

## Intent and why

Marauders has one environment. The Simulator, the owner's phone, TestFlight, `wrangler dev`, `db:migrate`, `db:purge`, the Simulator's dev-login and every spike reach the same Worker (`marauders-api`), the same Neon database and the same R2 bucket (`marauders-videos`). That is harmless while the data is the owner's own and dangerous the day real people use the app: a test clip, a migration run by hand, a purge typed in the wrong terminal and a login-as-test-user route all touch real users' data.

On 2026-11-19 the owner asked what CI/CD and infrastructure should do about environments. A read-only audit of the repo found:

- The app's base URL has one working source: the bundled `APIConfiguration.plist`. The build setting `INFOPLIST_KEY_MARAUDERS_API_BASE_URL` (the same production URL in **both** Debug and Release, since ead26d8) never reached an Info.plist, because Xcode ignores `INFOPLIST_KEY_` names it does not know. Checked on 2026-11-19 in four built bundles (the Oct 21 IPA and three Debug apps): each carries `APIConfiguration.plist` and no `MARAUDERS_API_BASE_URL` key. `APIConfiguration.resolveBaseURLString` reads the plist first and Info.plist second, and the second path has never been used. The app accepts https only.
- One git-ignored `backend/.dev.vars` (keys `DATABASE_URL`, `DEV_LOGIN_SECRET`) is read by `wrangler dev`, `db:migrate`, `db:purge` and the Simulator's `DevLogin`. `deployment/README.md` says `db:migrate` must point at production, not a Neon dev branch: the environment is chosen by editing a file. Wrangler itself falls back to the plain `.dev.vars` when `.dev.vars.<env>` is missing (`loadDotDevDotVars`), so `wrangler dev --env staging` would silently run against production's database until the files are split.
- `db:purge` deletes every `feed_videos` row, asks nothing and prints no target. It also calls `wrangler r2 object delete` per clip, but in wrangler 4.150.0 `r2 object put` and `r2 object delete` act on the **local simulator** unless `--remote` is passed (`isLocal(args, defaultValue = true)`, read in `wrangler-dist/cli.js`), and the script never passes it: real objects in `marauders-videos` are not deleted (an earlier purge would have left them, still served by `/v1/media/...`). `video:hls` has the same flaw and is worse: it puts its HLS segments in the local simulator and then repoints the row's `stream_url` at objects that do not exist remotely.
- `db:migrate` runs a hard-coded array of files (001 to 023, minus `004`) every time and tracks nothing; `docs/ci-cd.md` still says 001 to 022.
- `Jenkinsfile` builds the iOS app only. Worker deploys and migrations are by hand. No CI runs the backend although all eight `test:*` scripts are offline (esbuild plus in-process fakes of `neon()`); only `scripts/test-upload.mjs` hits production, on purpose.
- `/health` answers `{"status":"ok"}`: no environment, no version. `wrangler.toml` has no `[observability]`, so no log is kept.
- The Worker stores `stream_url` and `avatar_url` as absolute URLs built from the request's origin (`routes/upload.ts`, `routes/avatar.ts`), so a row is tied to the host that wrote it.
- Earlier findings that fit (not re-checked today): `/v1/auth/dev` is enabled on the production Worker (2026-11-15) and five test clips sit in production.

The repo `SomsakGitHub/Marauders` is **public** and GitHub Actions is enabled. As far as the owner's assistant knows a Cloudflare API token cannot be limited to one Worker, so a CI that deploys would hold a token able to change production plus the production `DATABASE_URL`.

The owner answered "ทำเลย" to a recommended set of five steps (scripts that name their environment, a staging Worker and database, the app pointing by configuration, backend CI, a `/health` that says what it is), and on the one fork that changes the build, **who holds the deploy keys**, chose **A: CI runs tests only; deploys are guarded scripts run from the owner's Mac.**

## Goals

1. A second environment, **staging**, with the same shape as production: its own Worker, R2 bucket, Neon database (empty, schema from the migrations), secrets and rate-limit namespace.
2. Every backend script that touches data or the cloud (`db:migrate`, `db:purge`, `deploy`, `dev`, `video:hls`, `test-upload`) takes an explicit `--env staging|production`. None defaults to production and none reads a shared secrets file.
3. Migrations are tracked and runnable from nothing: found by glob, applied in numeric order, recorded in a table, pending ones shown before they run, production asks for a confirmation phrase.
4. One guarded deploy script: says what it will touch, runs the tests first, asks a confirmation phrase for production, then migrates, deploys, smoke-checks the new version and prints the rollback command.
5. The app: Debug builds talk to staging, Release builds to production; a Debug-only override can point one run at production in one step; a Release build proves it carries the production URL and fails otherwise; dev-login is offered only against the host the Debug build was configured with.
6. `/health` reports environment and version; staging keeps its logs; production logging stays off, as the owner answered (Open for the owner).
7. CI (GitHub Actions) runs the typecheck and every offline backend test on each push and pull request, with no secret.
8. The decision and the how-to are written down (one ADR, the deployment guide, the CI guide, the README, ARCHITECTURE.md).
9. Production loses the dev-login secret (with the owner's yes, last).

## Non-goals (each stays a separate decision)

- **CI that deploys** (option B: staging on every push, production behind an approval in GitHub Environments). The deploy script is built so a workflow can call it later without a redesign. Revisit when a second developer joins, when external TestFlight testers arrive, or when manual deploys become a chore.
- A separate bundle id (`com.somsak.Marauders.dev`) and a third "Staging" configuration or TestFlight build. Known cost of the single bundle id: one phone that alternates a Debug-on-staging build and a TestFlight build is signed out at each switch, because the Keychain items (service `com.somsak.Marauders.auth`) are built with default arguments in about eight places and a token from one Worker is rejected by the other. Namespacing the Keychain by host is not a small change and is dropped.
- A custom domain and building media URLs at read time from a per-environment `PUBLIC_BASE_URL` (the absolute-URL finding above). Do it before the first public release.
- Copying production data into staging. Terraform or any infrastructure-as-code beyond `wrangler.toml`. A preview environment per pull request. Blue/green.
- iOS CI changes. Jenkins keeps building Release for TestFlight. Re-enabling its unit-test stage is not about environments and the owner disabled it on purpose; it is left out.
- The two device tests that read production fixtures with a plain GET (`DutchDubbingDeviceTests`, `LanguageDetectionDeviceTests`) stay as they are, a deliberate exception.
- The `dev:*` users and the five test clips already in production stay there until the owner removes them (the assistant never deletes production data).
- Real objects left in the production bucket by earlier purges: finding them needs a listing the assistant has no tool for, and removing them is the owner's decision.

## Anti-goals (a failure even if every test passes)

- The production Worker's name or URL changes (every installed app would break).
- Any forced sign-out, schema surprise or data change for production users.
- A secret value in the repo, a log line, a doc, a chat message or GitHub.
- A script that writes to production without `--env production` and its confirmation phrase.
- A Release or TestFlight build that can point at staging.
- The owner's day-to-day Debug flow made worse than it has to be: pointing a Debug run at production stays one step.

## Constraints

- Node 22 (the owner's Mac has 22.20.0), wrangler 4.150.0 (a devDependency; its `--env` also selects `.dev.vars.<env>`; `deploy --var` and `deployments list --json` exist), one Cloudflare account with the workers.dev subdomain `js6ctz7gtj`.
- In wrangler an environment does **not** inherit bindings, `vars` or `observability`: redeclare the R2 bucket, the two rate limiters, the vars and observability for staging. Checked offline on 2026-11-19 with `wrangler deploy --dry-run` on a scratch copy of the config: a staging block that redeclares them lists its own bucket, limiters and `ENVIRONMENT`; one that forgets them only prints a warning and would deploy a Worker with no storage. An environment Worker's name defaults to `<name>-<env>` (wrangler's documented behaviour). Do **not** add an `[env.production]` block: production stays the top-level config, otherwise its name becomes `marauders-api-production` and the URL changes.
- Once environments exist, a `wrangler deploy` with no `--env` still deploys the top level (production) and only prints a warning. The scripts therefore always pass the environment, `--env ""` for production (the explicit way to target the top level, checked), and the docs say never to run a bare `wrangler deploy`.
- Staging's URL is expected to be `https://marauders-api-staging.js6ctz7gtj.workers.dev` (derived, confirmed at the first deploy).
- Migration files stay re-runnable (`IF NOT EXISTS` and the like): production has never had a tracking table, so the first tracked run re-applies every file and records them, which is what every `db:migrate` already does. The script splits statements on `;`, so no `;` inside a SQL comment.
- The app target is a file-system-synchronized group: deleting `APIConfiguration.plist` needs no project edit. The two build-setting lines in `project.pbxproj` (Debug 467, Release 512 at the time of writing) are renamed to a plain user-defined `MARAUDERS_API_BASE_URL`, and `Marauders-ios/Config/Info-Additions.plist` (already the app target's `INFOPLIST_FILE` in both configurations, merged into the generated Info.plist because `GENERATE_INFOPLIST_FILE = YES`) gets the key `MARAUDERS_API_BASE_URL` with the value `$(MARAUDERS_API_BASE_URL)`. Whether Xcode really expands it into the built Info.plist is proven by the first build, before anything is deleted (section 5).
- The layer checker gets no new exception. The owner's uncommitted `RetryingHTTPClient.swift` edit and the two session-core docs stay untouched and uncommitted. App tests run on the iOS 27.2 simulator from a scratch copy (existing practice); nothing runs on a phone unless the owner asks.
- Every cloud change (create a bucket or a database, set or delete a secret, deploy production, turn logging on in production) needs the owner's explicit yes at that moment. Secret values never pass through the assistant's output: they move with shell redirection, random ones are generated and piped straight into `wrangler secret put` and the vars file, and the owner's Neon connection string comes in through the clipboard (`pbpaste`) or an editor.
- Production commands are run by the assistant only after the owner's yes for that step in chat (how migrations and deploys have run so far), or by the owner in a terminal. Either way a script's confirmation is a phrase: typed at a prompt when there is a terminal, passed as `--confirm "<phrase>"` when there is not. No flag skips the production confirmation.
- Public repo: GitHub Actions workflows take no secret, never use `pull_request_target`, and pin every action to a full commit SHA.

## Approaches considered

1. **Who holds the deploy keys** (the owner picked A).
   - **A, tests-only CI plus guarded scripts on the owner's Mac (chosen).** No credential outside the owner's machine and Cloudflare. Cost: no automatic deploy and no deploy history on GitHub; `/health`'s version makes drift visible.
   - B, CI deploys staging and production waits for an approval. Full history, but a Cloudflare token (account-wide Workers rights, so effectively production and its database) and the production `DATABASE_URL` live in a public repo's GitHub settings. Additive later.
   - C, no staging, only guards on production. Cheapest, but test data and unrehearsed migrations keep hitting the only database.
2. **How staging exists** (my pick).
   - **`[env.staging]` in the same `wrangler.toml` (chosen):** one file, one place to see the difference.
   - A second `wrangler.staging.toml`: duplicates config and drifts.
   - A Neon branch of production plus a copy of its bucket: copies real users' data, locations included, and production-host URLs.
3. **Staging database** (my pick). **A new, empty database filled by the migrations (chosen)**: no real data in staging, and 001 to 023 are proven on an empty database, which nobody has done since the first setup. A Neon project is the simplest; a schema-only branch of production is acceptable if the plan allows. The Worker only sees a different `DATABASE_URL`.
4. **How the app picks its environment** (my pick).
   - **A user-defined build setting per configuration, read through Info.plist, the plist deleted, plus a Debug-only override (chosen):** the safe default is non-production and Release cannot be switched at run time.
   - A runtime toggle in Settings: a mis-tap reaches production and the code ships in Release.
   - A third configuration: later (see non-goals).

## The design

### 1. One table of environments

A single data file readable by Node and by an Xcode build phase (JSON, read with `plutil -extract`; the builder may choose another format that both read) holds, per environment: wrangler env name, Worker name, URL, bucket, local vars file, whether dev-login is allowed and what a destructive command must be confirmed with.

| | staging | production |
|---|---|---|
| wrangler | `--env staging` | no `--env` (top-level) |
| Worker | `marauders-api-staging` | `marauders-api` (unchanged) |
| URL | `https://marauders-api-staging.js6ctz7gtj.workers.dev` | `https://marauders-api.js6ctz7gtj.workers.dev` |
| R2 bucket | `marauders-videos-staging` | `marauders-videos` |
| Neon | a new empty database | the existing one |
| vars file (local tooling only) | `backend/.dev.vars.staging` | `backend/.dev.vars.production` |
| dev-login | on, with its own `DEV_LOGIN_SECRET` | off (secret deleted) |
| rate-limit namespace | `1002` | `1001` |
| `JWT_SIGNING_SECRET` | its own, new | its own, unchanged |
| `APPLE_CLIENT_ID` | `com.somsak.Marauders` | `com.somsak.Marauders` |

No script contains the bucket name, a workers.dev host or `.dev.vars` outside this table (a test scans for them). A test also fails if the iOS project's Release URL differs from production's or Debug's from staging's.

### 2. The Worker (`backend/`)

- `wrangler.toml` (a sketch; the builder verifies what an environment inherits): top-level `[vars] ENVIRONMENT = "production"` (no observability, as the owner answered); `[env.staging]` with its own `vars`, `r2_buckets` (`VIDEOS` to `marauders-videos-staging`), the two `ratelimits` with namespace `1002`, and observability. Nothing else is renamed. A parity check keeps this honest: `npm test` runs `wrangler deploy --dry-run` for each environment (offline) and fails when a binding the top level has is missing in an environment, or on any "not inherited" warning.
- `Env` gains `ENVIRONMENT: string` and `GIT_SHA?: string`. `GET /health` answers `{"status":"ok","environment":"staging","version":"1d02680"}` (`"unknown"` and `"dev"` when unset); no auth, no secret in it. No other behaviour changes; `/v1/auth/dev` stays inert without `DEV_LOGIN_SECRET`.
- **Production logging:** the owner chose option 1 (Open for the owner), so this design enables observability for staging only. The Worker's other routes log no token, comment text or hash, but `upload.ts`, `avatar.ts` and `deleteVideo.ts` print whole driver error objects (`console.error("...", error)`) whose `detail` can echo row values, and Workers Logs stores a per-request record by default (URL paths here carry `@handles`; whether client IP or headers are stored could not be checked offline).

### 3. Scripts (`backend/scripts`, `package.json`)

- A shared helper parses `--env` (missing or unknown is an error), loads that environment's vars file without printing a value, and prints a banner: environment, Worker and URL, database host and name (user and password never shown), bucket. Confirmations are phrases (`production`, `purge staging`, `purge production`).
- **`db:migrate --env <e> [--dry-run]`**: finds `sql/NNN_*.sql` by glob in numeric order, never `004_purge_feed_videos.sql` (that is `db:purge`'s job); creates `schema_migrations(name text primary key, sha256 text not null, applied_at timestamptz not null default now())`; applies only files not recorded, recording a file only after all its statements ran; shows the pending list first; production asks for the phrase `production`. A recorded file whose hash changed stops the run with a clear message and an explicit, named way to accept it (the builder designs that escape hatch). The first tracked run on production re-applies everything (re-runnable files) and records it.
- **`db:purge --env <e>`**: banner, bucket from the table; deletes real R2 objects (every R2 call passes `--remote`; without it wrangler 4.150.0 touches only the local simulator); staging asks for the phrase `purge staging`, production for `purge production`. After this change the first purge really deletes objects, as the script always claimed.
- **`deploy --env <e>`**, in this order: banner; refuse production when `git status --porcelain backend` is not empty (staging allows it and marks the version `-dirty`); `npm test` must pass; the migration plan, applied (production: one `production` confirmation covers the migration and the deploy); `wrangler deploy --env <staging, or "" for production> --var GIT_SHA:<short sha>`; smoke check of `<url>/health` (status ok, environment as expected, version equal to what was deployed, a short retry for propagation); print the rollback command with the previous version id from `wrangler deployments list --json` when available. There is **no automatic rollback**: a database change cannot be rolled back and the owner decides.
- `package.json`: `deploy:staging`, `deploy:production`; bare `deploy` prints usage and exits non-zero (it must never deploy); `dev` runs through the helper, refuses to start when `.dev.vars.staging` is missing (wrangler would fall back to the plain file) and then runs `wrangler dev --env staging`; a `test` script runs the typecheck and every offline test (CI and `deploy` both run it). No script ever starts a local Worker against production.
- `video:hls` and `test-upload` take `--env` and read the bucket and URL from the table; `video:hls` passes `--remote` and repoints `stream_url` with the environment's own URL (it is fixed, not retired; the owner can retire it instead); `test-upload` defaults to staging.
- `.dev.vars` retires: after the transition the plain file is deleted so a tool that still reads it fails loudly. `.gitignore` covers `backend/.dev.vars*` except an example; `backend/.env.example` becomes `backend/.dev.vars.example` (names only, no values).

### 4. Resources and rollout (each cloud step waits for the owner's yes)

1. Code, scripts, tests and docs in a scratch copy; commit on the owner's order. Nothing is deployed.
2. The owner creates the empty Neon database for staging and puts its pooled connection string on the clipboard. Then: `.dev.vars.staging` from the clipboard; `wrangler r2 bucket create marauders-videos-staging`; `wrangler secret put --env staging` for `DATABASE_URL`, a new random `JWT_SIGNING_SECRET`, `APPLE_CLIENT_ID` and a new random `DEV_LOGIN_SECRET` (also written to `.dev.vars.staging`).
3. `db:migrate --env staging` on the empty database, twice (the second run changes nothing); fix what breaks. `deploy --env staging`. Check: `/health` says staging and a version; `/v1/feed` is empty; `/v1/auth/dev` answers 200 with the staging secret and 404 without it.
4. The app change, tested on the simulator against staging (section 5).
5. Production: `.dev.vars` is split by shell (`DATABASE_URL` only goes to `.dev.vars.production`); `db:migrate --env production --dry-run`, then the first tracked run; `deploy --env production` (the new `/health`; production logging stays off, as the owner chose).
6. Last, only after the app change is committed and the owner's Simulator has used staging: `wrangler secret delete DEV_LOGIN_SECRET` for production (after `wrangler secret list` shows it is set), then `/v1/auth/dev` must answer 404.
7. The owner pushes; the workflow runs.

### 5. The app (`Marauders-ios`)

- `APIConfiguration`: the base URL comes from the Info.plist key `MARAUDERS_API_BASE_URL` only, fed by a user-defined build setting of the same name through `$(MARAUDERS_API_BASE_URL)` in `Info-Additions.plist`. **Order matters:** first rename the setting and add the key, build both configurations and read the key out of each built Info.plist; only then delete `APIConfiguration.plist` (until then every build still works through it). If Xcode does not expand it, write the key with a Run Script phase and PlistBuddy instead. Under `#if DEBUG` an environment variable `MARAUDERS_API_BASE_URL` (the Xcode scheme's, or `SIMCTL_CHILD_` for `simctl`) wins when set, with the same validation (https, no path). The resolution is a small pure function so a test can cover it, and a new `APIConfiguration` test file does (there is none today).
- Build settings: the user-defined `MARAUDERS_API_BASE_URL` is staging's URL in Debug and production's in Release (the old `INFOPLIST_KEY_` lines are removed). Unit tests never touch the network, so the test target is unaffected.
- **Release guard:** a Release-only Run Script phase (`Marauders-ios/Scripts/check-release-config.sh`) reads the built Info.plist and fails the build unless `MARAUDERS_API_BASE_URL` equals production's URL from the table and no `APIConfiguration.plist` is in the bundle. It has script tests beside `check-layers-tests.sh` (passes; wrong URL; missing key; stray plist). Jenkins builds Release for TestFlight, so a bad build cannot be uploaded.
- **`DevLogin`:** the secret now comes from `backend/.dev.vars.staging`; it is offered only when the base URL in use is the configured default, never an override, so the secret cannot be sent to production or to any other host. The rule is a pure function with a unit test.
- Debug-only: the existing Debug "Log" tab shows the resolved API host at its top (no localization; Debug builds only). The app already logs `api base host=`.
- Untouched: the Keychain stores and the auth package, Release behaviour apart from where the URL is read, `UITEST` mock mode, the layer exceptions.
- Known cost, said in the docs: a Debug run on staging shows an empty feed until test clips are uploaded to staging through the app; one phone alternating Debug and TestFlight builds signs in again at each switch; the startup feed cache (two clips, six hours, absolute URLs, not keyed by host) may show up to two clips of the other environment on the first screen after a Debug run flips between staging and production, until the feed loads. All accepted.

### 6. CI (`.github/workflows/backend.yml`)

- Triggers: `push` to `main` and `pull_request`, limited to `backend/**`, the workflow file, `Marauders-ios/Marauders.xcodeproj/project.pbxproj` and `Marauders-ios/Config/Info-Additions.plist` (the URL agreement test reads them), plus `workflow_dispatch`. `permissions: contents: read`; a `concurrency` group that cancels a superseded run; no secret; no `pull_request_target`.
- Steps: checkout, `setup-node` (22, npm cache keyed on `backend/package-lock.json`), `npm ci`, `npm test`. Actions pinned to full commit SHAs resolved with `gh api`, the version in a comment.
- GitHub holds no secret. The owner pushes straight to `main`, so a failure shows as a failed run (mail, `gh run list`), not as a blocked merge.

### 7. Docs

A new `docs/adr/010-environments.md` (decision, the A and B trade, the public-repo and token reasoning, the triggers to revisit) and its row in `docs/adr/README.md`; `deployment/README.md` (environments table, the `--env` commands, the order, rollback, the staging resources); `docs/ci-cd.md` (the backend section, the workflow, the end of "deploy by hand"); `README.md` (dev login now uses staging; the production note at line 246); `ARCHITECTURE.md` (the dev-login rows and an Environments section); the 022 versus 023 mismatch removed by naming no last number.

## Verification (what "done" means)

- Backend, offline, in `npm test` and run in a clean clone (`npm ci && npm test`, no `.dev.vars`, no network): the environment table and the no-hard-coded-names scan; the iOS URLs agree with the table; the migration planner as pure functions (glob order, `004` excluded, pending, changed and unknown detection); target parsing, banners and confirmation rules (missing or unknown `--env`, production needs its phrase, a dirty tree is refused for production); `/health` for each environment; binding parity across environments.
- App, on the iOS 27.2 simulator: `APIConfiguration` resolution (value, override, https only, path rejected) and the `DevLogin` rule; the Release check's script tests; a Debug build whose built Info.plist holds staging's URL, and an unsigned Release archive whose built Info.plist holds production's URL, with no plist, passing the check and failing it when forced to staging; the layer checker clean; the unit suite green and the UI suite run once at the end.
- Real: staging from empty (migrate twice), the staging deploy and its smoke check, the Simulator's dev-login against staging with a Debug build, one clip uploaded to staging through the app; the production steps checked with `/health` and `curl` (`/v1/auth/dev` is 404).
- CI: green on GitHub after the owner's push.

## Open for the owner

**Production logging: answered 2026-11-19.** The owner approved the design with option 1, staging only for now. The options were: (1) staging only for now; (2) production with `invocation_logs = false`, so only our own `console` lines are kept, after trimming those three routes' error logs to SQLSTATE and message as the comments routes already do; (3) production with the defaults. Changing it later is one config line (plus the trimming for 2).

## Calls I made (the owner can reverse any)

Staging database empty, not a copy · the Worker names and the staging URL · production stays the top-level wrangler config · Debug points at staging by default with a Debug-only override, an empty staging feed accepted · `APIConfiguration.plist` deleted · dev-login only on the configured default host · production deploy refuses a dirty backend tree · bare `npm run deploy` no longer deploys · the plain `.dev.vars` is deleted · observability on in staging only for now · GitHub Actions with SHA-pinned actions and no secret · Jenkins left alone, including its unit-test stage · the two device tests keep reading production · a tracking table with checksums replaces the hard-coded list · ADR 010 · production confirmations are phrases (typed, or `--confirm` after the owner's chat yes) · every R2 call passes `--remote` · `video:hls` is fixed, not retired · `npm run dev` refuses without its vars file · production logging stays off (the owner approved option 1).

## What is left to the builder

File and function names; banner wording and the flags beyond those named; the escape hatch for a changed migration; how `deploy` finds the previous version id; the format of the shared environments file; the placement of the Debug host line; the two `project.pbxproj` edits and the new build phase; the SHAs for the pinned actions; the test structure (reuse the esbuild-and-fakes pattern and the shell script tests).

Facts to verify while building, not assume: that a build of each configuration puts `MARAUDERS_API_BASE_URL` into its Info.plist (first, before the plist is deleted); the real staging URL; that migrations 001 to 023 run on an empty database; that the Neon plan allows the second database (the owner's console); that production's `DEV_LOGIN_SECRET` is set before it is deleted.
