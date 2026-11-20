// A wrangler environment inherits no bindings, vars or observability: whatever the top level (production) has, staging
// must repeat. This test asks wrangler itself what each environment would deploy (`deploy --dry-run` needs no
// Cloudflare login and uploads nothing) and compares the bindings of the two.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { BACKEND_DIR, loadEnvironments } from "../../scripts/lib/targets.mjs";

const WRANGLER = path.join(BACKEND_DIR, "node_modules", ".bin", "wrangler");

/** The rows of the "Your Worker has access to the following bindings" table of `wrangler deploy --dry-run`. */
function parseBindings(output) {
  const bindings = [];
  for (const line of output.split(/\r?\n/)) {
    const match = /^env\.([A-Za-z0-9_]+)(?: \((.*)\))?\s{2,}(\S.*?)\s*$/.exec(line);
    if (match) {
      bindings.push({ binding: match[1], detail: match[2] ?? "", type: match[3] });
    }
  }
  return bindings;
}

function dryRun(wranglerEnv) {
  const outdir = mkdtempSync(path.join(tmpdir(), "marauders-parity-"));
  try {
    const run = spawnSync(WRANGLER, ["deploy", "--dry-run", "--env", wranglerEnv, "--outdir", outdir], {
      cwd: BACKEND_DIR,
      encoding: "utf8",
      env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "true", NO_COLOR: "1" },
    });
    return { status: run.status, output: `${run.stdout}\n${run.stderr}` };
  } finally {
    rmSync(outdir, { recursive: true, force: true });
  }
}

test("parseBindings reads wrangler's table", () => {
  const output = [
    "Total Upload: 383.95 KiB / gzip: 89.80 KiB",
    "Your Worker has access to the following bindings:",
    "Binding                                       Resource        ",
    "env.VIDEOS (marauders-videos-staging)         R2 Bucket       ",
    "env.RATE_LIMITER (120 requests/60s)           Rate Limit      ",
    'env.ENVIRONMENT ("staging")                   Environment Variable',
    "",
    "--dry-run: exiting now.",
  ].join("\n");
  assert.deepEqual(parseBindings(output), [
    { binding: "VIDEOS", detail: "marauders-videos-staging", type: "R2 Bucket" },
    { binding: "RATE_LIMITER", detail: "120 requests/60s", type: "Rate Limit" },
    { binding: "ENVIRONMENT", detail: '"staging"', type: "Environment Variable" },
  ]);
  assert.deepEqual(parseBindings("nothing to see here"), []);
});

test("every environment deploys the same bindings, each to its own resources", () => {
  const environments = loadEnvironments();
  const seen = {};
  for (const [name, config] of Object.entries(environments)) {
    const { status, output } = dryRun(config.wranglerEnv);
    assert.equal(status, 0, `${name}: wrangler deploy --dry-run failed\n${output}`);
    assert.ok(
      !output.includes("exists at the top level, but not on"),
      `${name}: a binding of the top level is missing here\n${output}`,
    );
    assert.ok(
      !output.includes("no target environment was specified"),
      `${name}: this is the argument form scripts/deploy.mjs uses, and wrangler must not warn about it\n${output}`,
    );
    const bindings = parseBindings(output);
    assert.deepEqual(
      bindings.map((entry) => entry.binding).sort(),
      ["AUTH_RATE_LIMITER", "ENVIRONMENT", "RATE_LIMITER", "VIDEOS"],
      `${name}: binding names\n${output}`,
    );
    const byName = Object.fromEntries(bindings.map((entry) => [entry.binding, entry]));
    assert.equal(byName.VIDEOS.detail, config.bucket, `${name}: the bucket`);
    assert.ok(byName.ENVIRONMENT.detail.includes(`"${name}"`), `${name}: ENVIRONMENT is ${byName.ENVIRONMENT.detail}`);
    seen[name] = byName;
  }
  for (const limiter of ["RATE_LIMITER", "AUTH_RATE_LIMITER"]) {
    assert.equal(seen.staging[limiter].detail, seen.production[limiter].detail, `${limiter} must allow the same rate`);
  }
});
