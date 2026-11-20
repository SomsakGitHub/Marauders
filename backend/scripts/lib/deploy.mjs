// The testable parts of `npm run deploy:<env>` and `npm run dev`.
//
// A deploy runs in this order and stops at the first failure: banner, clean-tree check (production), tests,
// the migration plan (a dry run), confirmation phrase, the version that serves now, migrations, wrangler deploy,
// `/health` check, rollback hint.
// There is no automatic rollback: a half-finished state is shown to the person, with the command that undoes the
// Worker (a rollback does not undo migrations).
//
// A bare `wrangler deploy` still targets production and only warns. Nothing here or in package.json produces one:
// every wrangler call names its environment (`--env staging`, or `--env ""` for the top level, which is production).

import { setTimeout as sleepFor } from "node:timers/promises";

import { UsageError, banner, loadEnvironments, loadVars } from "./targets.mjs";

/** The label a deploy stamps on the Worker (`GIT_SHA`): the short commit, with `-dirty` when backend/ has changes. */
export function versionLabel(shortSha, dirtyBackend) {
  return dirtyBackend ? `${shortSha}-dirty` : shortSha;
}

/** True for any output of `git status --porcelain -- backend`, an untracked new file included. */
export function isDirty(porcelain) {
  return porcelain.trim() !== "";
}

/** The wrangler arguments of a deploy. Production's `--env` value is the empty string: an argument, not a dropped one. */
export function wranglerDeployArgs(config, version) {
  return ["deploy", "--env", config.wranglerEnv, "--var", `GIT_SHA:${version}`];
}

/** Production is deployed only from a clean backend/, so its `/health` version names a commit that exists. */
export function assertDeployable(name, dirtyBackend) {
  if (name === "production" && dirtyBackend) {
    throw new UsageError(
      "production is deployed from a clean backend/: commit or stash the changes first (see git status -- backend)",
    );
  }
}

/**
 * Asks `<url>/health` until it reports the environment and version that was just deployed. The old version can keep
 * answering for a few seconds after wrangler returns, so a stale answer is retried; the failure reason names what was
 * expected and what answered.
 */
export async function checkHealth({ url, expectedEnvironment, expectedVersion, fetchFn, attempts, delayMs, sleep }) {
  let reason = "no attempt was made";
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetchFn(`${url}/health`, { headers: { "cache-control": "no-cache" } });
      if (!response.ok) {
        reason = `${url}/health answered HTTP ${response.status}`;
      } else {
        const body = await response.json();
        if (body?.environment === expectedEnvironment && body?.version === expectedVersion) {
          return { ok: true };
        }
        reason = `expected environment ${expectedEnvironment} version ${expectedVersion}, but ${url}/health says environment ${String(body?.environment)} version ${String(body?.version)}`;
      }
    } catch (error) {
      reason = `${url}/health could not be read (${error?.name ?? "error"})`;
    }
    if (attempt < attempts) {
      await sleep(delayMs);
    }
  }
  return { ok: false, reason };
}

/** What to run to put the Worker back. `previousVersionId` is null on a first deploy or when the list could not be read. */
export function rollbackHint(name, config, previousVersionId) {
  if (previousVersionId) {
    return `to undo this ${name} deploy: npx wrangler rollback ${previousVersionId} --name ${config.worker}   (a rollback does not undo migrations)`;
  }
  return `no previous version is known for ${config.worker}; see its history with: npx wrangler deployments list --name ${config.worker}`;
}

/**
 * The version that was serving, from `wrangler deployments list --json`: the newest deployment's version with the
 * largest share. The JSON may be an array or `{ deployments: [...] }`; anything else, or anything missing, is null.
 */
export function currentVersionId(text) {
  const start = text.search(/[[{]/);
  if (start < 0) {
    return null;
  }
  let parsed;
  try {
    parsed = JSON.parse(text.slice(start));
  } catch {
    return null;
  }
  const deployments = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.deployments) ? parsed.deployments : null;
  if (!deployments) {
    return null;
  }
  const newest = deployments
    .filter((deployment) => Array.isArray(deployment?.versions) && deployment.versions.length > 0)
    .reduce((best, deployment) => (best === null || Date.parse(deployment.created_on) > Date.parse(best.created_on) ? deployment : best), null);
  if (!newest) {
    return null;
  }
  const serving = newest.versions
    .filter((version) => typeof version?.version_id === "string")
    .reduce((best, version) => (best === null || (version.percentage ?? 0) > (best.percentage ?? 0) ? version : best), null);
  return serving ? serving.version_id : null;
}

/**
 * Runs the deploy through the injected `steps`, so the order and the stops are testable without wrangler, npm or the
 * network. `databaseUrl` only feeds the banner (host and database name). `health` tunes the `/health` retries.
 */
export async function runDeploy({ name, config, databaseUrl, git, steps, confirm, fetchFn, log, health = {} }) {
  const { attempts = 10, delayMs = 3000, sleep = (ms) => sleepFor(ms) } = health;
  log(banner({ name, config, action: "deploy", databaseUrl }));
  const dirtyBackend = await git.dirtyBackend();
  assertDeployable(name, dirtyBackend);
  const version = versionLabel(await git.shortSha(), dirtyBackend);
  log(`   version  ${version}`);

  await steps.runTests();
  // The migration plan comes before the phrase, so the person sees what will be applied (and an applied file that was
  // edited stops the run here) before typing it.
  await steps.showMigrationPlan();
  await confirm(config.confirm.write);
  const previous = await steps.previousVersionId();
  await steps.migrate();
  await steps.wranglerDeploy(wranglerDeployArgs(config, version));

  const result = await checkHealth({
    url: config.url,
    expectedEnvironment: name,
    expectedVersion: version,
    fetchFn,
    attempts,
    delayMs,
    sleep,
  });
  const hint = rollbackHint(name, config, previous);
  if (!result.ok) {
    log(hint);
    throw new Error(`deployed, but the health check failed: ${result.reason}`);
  }
  log(`healthy: ${config.url}/health reports ${name} ${version}`);
  log(hint);
}

/** `npm run dev` runs the staging Worker only: another environment, in any spelling, is refused. */
export function wranglerDevArgs(extraArgs) {
  for (const arg of extraArgs) {
    if (arg === "--env" || arg.startsWith("--env=") || (arg.startsWith("-e") && !arg.startsWith("--"))) {
      throw new UsageError("npm run dev always runs staging, so --env is not accepted (production has no local server)");
    }
  }
  return ["dev", "--env", "staging", ...extraArgs];
}

/**
 * `wrangler dev --env staging` silently falls back to a vars file with no environment in its name (production's
 * database, in the old setup) when `.dev.vars.staging` is missing, so the dev script refuses to start without it.
 */
export function assertStagingVars(backendDir) {
  loadVars(loadEnvironments().staging, backendDir);
}
