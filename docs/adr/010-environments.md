# ADR-010: Environments: scripts that name their target, one backend for now, staging ready

**Status:** Accepted, amended twice on 2026-11-20 (one backend for now: see the Amendment; two builds of the app: see the Second amendment)  
**Date:** 2026-11-19  
**Scope:** `backend/wrangler.toml`, `backend/environments.json`, `backend/scripts/**`, `.github/workflows/backend.yml`, and the app's configuration (`Marauders.xcodeproj` build settings, build configurations and the two shared schemes, `Config/Info-Additions.plist`, `Shared/Configuration/APIBaseURL.swift`, `Data/API/APIConfiguration.swift`, `Shared/Configuration/DevLogin.swift`, `Presentation/Debug/DebugLogView.swift`, `Scripts/check-release-config.sh`)

## Amendment, 2026-11-20: one backend for now

When the first cloud step came (creating staging's Neon database), the owner decided that the app's "staging" and "prod" sides, the Debug and the Release builds, **both talk to the one production backend** for now. Nothing was created for staging in Neon, R2 or Cloudflare. The decision below stands as the design, with these changes:

- **Staging is defined but not provisioned.** Its row in `backend/environments.json`, `[env.staging]` in `wrangler.toml`, `deploy:staging`, `--env staging` on every script and the tests that cover them stay, so provisioning it later means creating resources (`deployment/README.md`), not writing code. Until then a staging command stops at the missing `.dev.vars.staging` (`test-upload` would post to a Worker that does not exist) and `npm run dev`, which is staging-only, does not start.
- **Debug builds talk to production**, like Release builds. The Debug build setting is production's URL. `backend/test/scripts/iosEnvironments.test.mjs` names that choice in one constant, `DEBUG_ENVIRONMENT`, and fails unless the Debug URL and the vars file `DevLogin` reads both belong to that environment, so pointing Debug at staging later is one deliberate change in three places.
- **Production keeps its dev-login secret.** The Simulator signs in through `/v1/auth/dev` on the one backend, so deleting production's `DEV_LOGIN_SECRET` is cancelled and `DevLogin` reads the secret from the git-ignored `backend/.dev.vars.production`. The route only mints sessions for `dev:<label>` users, which cannot collide with a real Apple subject, and answers 404 unless the secret is set; but whoever holds the secret can create test users, clips and comments on the real backend.
- **Costs the owner accepted:** Debug and Simulator runs, test clips and `dev:*` users live in the database and bucket real people will use; a migration cannot be rehearsed on a second database (the offline tests and `db:migrate --dry-run` still run first); the first production deploy with the new script has no staging rehearsal.
- **Unchanged:** scripts that name their target, the confirmation phrases, tracked migrations, `/health` with the version, the Release guard, tests-only CI.
- **Revisit before** the first public release, external TestFlight testers or a second developer: provision staging, point Debug at it (the three places above), then delete production's dev-login secret.

## Second amendment, 2026-11-20 (later): two builds of the app, Staging and Production

With one backend, "Debug" and "Release" no longer said anything about where a build connects, only about what is compiled in. The owner asked for the two builds to be named for what they are: **Staging** (run from Xcode; has the in-app log and the Debug aids) and **Production** (TestFlight and the App Store; has no in-app log), both on the production backend. Design: [2026-11-20-app-environments-design.md](../superpowers/specs/2026-11-20-app-environments-design.md). In the rest of this record, "Debug" and "Release" for the app's builds mean `Debug-Staging` and `Release-Production`.

- **Two build configurations, two shared schemes.** The configurations were renamed in place, `Debug` to `Debug-Staging` and `Release` to `Release-Production` (the default is `Release-Production`). `Marauders Staging` runs, tests and analyzes with `Debug-Staging`, profiles and archives with `Release-Production`, and holds `MaraudersTests` and `MaraudersUITests`. `Marauders Production` builds `Release-Production` for every action and has no tests; Jenkins and the fastlane `build` lane use it. The old `Marauders` scheme is gone. **The name of the debug side must contain `Debug`**: Xcode gives the local package `MaraudersAuth` the `DEBUG` flag only to a configuration whose name does, and a configuration named just `Staging` did not compile `DevAuthAPIClient`.
- **The in-app log is a Staging feature.** `DebugLogView` and the banner's "View Log" link (`CopyableStatusBanner`) sit inside `#if DEBUG`, so a Production build contains neither; the Log tab already did. `AppLogStore` still records in every build.
- **The Production guard now looks inside the executable too.** `Scripts/check-release-config.sh` takes a required `--executable <path>` and fails the build when that file contains the name of a Debug-only type. The names are one list in the script (`DebugLogView`, `DevAuthAPIClient`), and `backend/test/scripts/iosEnvironments.test.mjs` fails if a name on it is not declared in the sources, so a rename cannot turn the check into a no-op. The Run Script phase still runs only for `Release-Production`, and now declares the executable as an input.
- **Same bundle id, same backend.** `com.somsak.Marauders` stays: the Worker has one `APPLE_CLIENT_ID`, and a second id would mean a second Sign in with Apple setup for no gain while there is one backend. Both builds are built for production's URL; what separates them is what is compiled in, not where they connect.
- **Costs accepted:** TestFlight builds lose the "View Log" link (the Log tab was never in them), so a tester's phone cannot show the log; commands outside this repository that name the old scheme (an alias, a job somewhere else) need the new names; the first build after the rename is a full rebuild; a Debug-only type added later is kept out of Production by `#if DEBUG`, and the guard checks that only for the names on its list, so a new one that must stay out gets its name added there.
- **Alternatives considered:** keep `Debug` and `Release` and only add schemes (cheapest, nothing renames, but the configurations would not be separated by environment, as the owner asked, and only a scheme's name would say which build is which); four configurations, a Debug and a Release for each environment (twice the build settings to keep in step, for no difference while the backend is one).

## Context

Until 2026-11-19 Marauders had one environment. The Simulator, the owner's phone, TestFlight, `wrangler dev`, `db:migrate`, `db:purge`, the Simulator's dev login and every spike reached the same Worker (`marauders-api`), the same Neon database and the same R2 bucket (`marauders-videos`). That is harmless while the data is the owner's own. It stops being harmless the day other people use the app: a test clip, a migration run by hand, a purge typed in the wrong terminal and a "log in as a test user" route all touch real users' data.

A read-only audit that day found:

- **The app's URL had one working source**, the bundled `APIConfiguration.plist`. The build setting `INFOPLIST_KEY_MARAUDERS_API_BASE_URL` (the same production URL in Debug and Release) never reached an Info.plist, because Xcode ignores `INFOPLIST_KEY_` names it does not know. Four built bundles were checked: each carried the plist and no `MARAUDERS_API_BASE_URL` key.
- **One git-ignored `backend/.dev.vars`** was read by `wrangler dev`, `db:migrate`, `db:purge` and the Simulator's dev login, and the deployment guide told the owner to point `db:migrate` at production: the environment was chosen by editing a file. Wrangler falls back to the plain file when `.dev.vars.<env>` is missing, so `wrangler dev --env staging` would have run against production's database.
- **`db:purge` asked nothing and printed no target**, and its R2 calls (like `video:hls`'s) did not pass `--remote`: in wrangler 4.150.0 `r2 object put` and `delete` act on the local simulator unless told otherwise, so earlier purges removed rows and left the real objects.
- **`db:migrate` ran a hard-coded list of files every time and tracked nothing.**
- **No CI ran the backend**, although all its tests are offline. `/health` answered `{"status":"ok"}`: no environment, no version.
- The repository is **public** and GitHub Actions is enabled. As far as we know a Cloudflare API token cannot be limited to one Worker, so a CI that deployed would hold a token able to change production, plus production's `DATABASE_URL`.

## Decision

**A second environment, staging, with the same shape as production** (defined, not provisioned: see the Amendment), and every script and build that touches data says which one it means.

| | staging | production |
|---|---|---|
| provisioned | no (Amendment) | yes |
| wrangler | `--env staging` | no `--env` (the top level) |
| Worker | `marauders-api-staging` | `marauders-api` (name and URL unchanged) |
| R2 bucket | `marauders-videos-staging` | `marauders-videos` |
| Neon | its own empty database, filled by the migrations | the existing one |
| vars file (local tooling) | `backend/.dev.vars.staging` | `backend/.dev.vars.production` |
| dev login | on, with its own `DEV_LOGIN_SECRET` | on while there is one backend (Amendment), off once staging exists |
| observability | on | off |
| rate-limit namespace | `1002` | `1001` |

- **One table, `backend/environments.json`**, holds the Worker name, URL, bucket, vars file and confirmation phrases of each environment. Node reads it, and so does the iOS Release guard (`plutil -extract`). A test fails if a script, `package.json` or the example vars file names a bucket, a workers.dev host or the plain `.dev.vars` outside it.
- **Production stays the top-level wrangler config.** A block `[env.production]` would rename the Worker to `marauders-api-production` and change the URL every installed app calls. A wrangler environment inherits no bindings, vars or observability, so `[env.staging]` repeats them, and a test runs `wrangler deploy --dry-run` for both environments and compares their bindings.
- **Every script takes `--env staging|production` and has no default** (`npm run dev` is staging only, so it does not start until staging exists). Each reads only the vars file of the environment it was told to use, prints a banner (environment, Worker, URL, database host and name, bucket, never a credential) and, for a write to production, asks for a confirmation phrase: typed at a terminal, or passed as `--confirm "<phrase>"` when there is none. No flag skips it. The phrases are `production`, `purge staging` and `purge production`.
- **One database per environment.** The table separates the Worker, the URL and the bucket, but the database is only whatever `DATABASE_URL` a vars file holds, so a copied file would make a `--env staging` command change production's data. Reading a vars file therefore fails when another environment's vars file names the same server and database (the pooled and the direct string of one server count as the same; the role, the password and the options do not matter), and the message names the two files, never a value. `npm run dev` goes through the same check.
- **Migrations are tracked.** `sql/NNN_*.sql` are found by glob and applied in numeric order, never `004_purge_feed_videos.sql`; `schema_migrations(name, sha256, applied_at)` records a file only after all its statements ran; the pending list is shown first (`--dry-run` stops there); a recorded file whose hash changed stops the run until it is named with `--accept-changed <file>`. Files stay re-runnable, because production has never had a tracking table and its first tracked run re-applies everything and records it.
- **`npm run deploy:<env>` is the only deploy.** Its order is: banner; production refuses a `backend/` with uncommitted changes; the whole `npm test`; the migration plan, as a dry run that shows what is pending and stops on an applied file that was edited; the confirmation phrase; the version that serves now; migrations; `wrangler deploy --env <env> --var GIT_SHA:<short sha>`; a check of `<url>/health` for the environment and the version just deployed; the rollback command. There is no automatic rollback, because a database change cannot be rolled back and the owner decides. A bare `wrangler deploy` still targets production and only warns, so no script and no `package.json` entry runs one, and the guides say never to.
- **`/health` says what is running**: `{"status":"ok","environment":"production","version":"1d02680"}`.
- **The app reads its URL from Info.plist only.** The user-defined build setting `MARAUDERS_API_BASE_URL` is production's URL in Release and, while there is one backend (Amendment), in Debug too, and `Config/Info-Additions.plist` hands it to the built Info.plist as `$(MARAUDERS_API_BASE_URL)`; both builds were read back with `plutil` before the bundled plist was deleted. A Debug run can be pointed elsewhere by an environment variable of the same name (`SIMCTL_CHILD_MARAUDERS_API_BASE_URL` for `simctl`), validated like the build's value and never silently replaced by it; Release ignores the process environment.
- **A Release build proves it is for production.** A Release-only Run Script phase runs `Scripts/check-release-config.sh` on the built app and fails the build unless `MARAUDERS_API_BASE_URL` equals production's URL from the table and no `APIConfiguration.plist` is in the bundle. Jenkins builds Release for TestFlight, so a build with the wrong URL cannot be uploaded.
- **Dev login follows the configured host.** The Simulator's secret comes from the vars file of the environment the Debug builds use (`backend/.dev.vars.production` today) and is offered only while the app talks to the host its build was configured with, never to an override. Production keeps its `DEV_LOGIN_SECRET` while there is one backend (Amendment); it belongs to staging alone once that exists.
- **CI runs tests and nothing else.** `.github/workflows/backend.yml` runs `npm ci` and `npm test` on pushes to `main`, on pull requests and by hand, with `permissions: contents: read`, no secret, no `pull_request_target` and every action pinned to a commit SHA. Deploys and migrations stay scripts the owner runs from their own Mac.

## Consequences

- No credential that can change production lives outside the owner's machine and Cloudflare. Once staging is provisioned, a test clip, a migration rehearsal or an experiment has somewhere to go that is not the real database; until then (Amendment) they go to production.
- Once provisioned, staging is filled from nothing by the migrations, which proves 001 to 023 on an empty database, something nobody has done since the first setup.
- The first `db:purge` after this change really deletes R2 objects, as the script always claimed. It is never run on production as part of the rollout.
- **Costs we accept:**
  - There is no automatic deploy and no deploy history on GitHub; `/health`'s version makes drift visible.
  - Once Debug points at staging, one phone that alternates a Debug build and a TestFlight build signs in again at each switch: the Keychain items are not namespaced by host (they are built in about eight places) and a token from one Worker is rejected by the other.
  - Once Debug points at staging, a Debug run shows an empty feed until clips are uploaded to staging through the app.
  - The startup feed cache (two clips, six hours, absolute URLs, not keyed by host) can show up to two clips of the other environment for a moment after a Debug run flips between staging and production.
  - The Worker stores `stream_url` and `avatar_url` as absolute URLs built from the request's origin, so a row is bound to the host that wrote it.
  - Production logging stays off: three routes print whole driver error objects whose detail can echo row values, and Workers Logs keeps a record per request. Staging's config has it on.
  - Two device tests read production fixtures with a plain GET; they stay as they are.
- A mistake that remains possible: a bare `npx wrangler deploy` typed by hand still deploys production.

## Triggers to revisit

- A second developer joins, or external TestFlight testers arrive, or before the first public release: provision staging, point Debug at it and delete production's dev-login secret (Amendment); also consider B below, and a separate bundle id with its own Keychain namespace.
- Manual deploys become a chore: let CI deploy staging on every push and production behind an approval (GitHub Environments), calling the same script.
- Before the first public release: a custom domain, and media URLs built at read time from a per-environment base URL instead of stored absolute URLs.
- Someone needs production logs: turn observability on with `invocation_logs = false` after trimming the three routes' error logs to SQLSTATE and message, as the comments routes already do.

## Alternatives considered

1. **Who holds the deploy keys.**
   - **A, tests-only CI plus guarded scripts on the owner's Mac (chosen).** The owner's choice: nothing outside their machine can change production.
   - B, CI deploys staging and production waits for an approval. A full history, but a Cloudflare token with account-wide Workers rights, effectively production and its database, would sit in a public repository's settings. It can be added later without redesign: the deploy script is what a workflow would call.
   - C, no staging, only guards on production. Cheapest, but test data and unrehearsed migrations keep hitting the only database. This is what the owner chose on 2026-11-20 for now, with staging's code and docs kept ready (Amendment).
2. **How staging exists.** `[env.staging]` in the same `wrangler.toml` (chosen: one file shows the difference) over a second `wrangler.staging.toml` (duplicates and drifts) or a Neon branch of production with a copy of its bucket (copies real users' data, locations included, and production-host URLs).
3. **How the app picks its environment.** A build setting per configuration read through Info.plist, plus a Debug-only override (chosen: the safe default is non-production and a Release build cannot be switched at run time) over a runtime toggle in Settings (a mis-tap reaches production, and the code ships in Release) or a third build configuration (later, with the separate bundle id).
