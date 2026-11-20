// Guards against the habits that made one environment dangerous: a script that names its own host, bucket or vars
// file, a package.json entry that calls wrangler without `--env`, and a vars file that could be committed.
// (A hand-typed `npx wrangler deploy` still targets production and only warns: nothing can stop that, so nothing in
// this repository may produce one.)
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import { BACKEND_DIR, loadEnvironments } from "../../scripts/lib/targets.mjs";

const REPO_DIR = path.resolve(BACKEND_DIR, "..");

function scriptFiles() {
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) walk(path.join(dir, entry.name));
      else if (entry.name.endsWith(".mjs")) files.push(path.join(dir, entry.name));
    }
  };
  walk(path.join(BACKEND_DIR, "scripts"));
  return files;
}

test("no script names a host, a bucket or the plain vars file", () => {
  const files = scriptFiles();
  assert.ok(files.length > 10, "the scan found the scripts");
  const forbidden = [
    "workers.dev",
    ...Object.values(loadEnvironments()).flatMap((config) => [config.bucket, config.url]),
  ];
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    const name = path.relative(BACKEND_DIR, file);
    for (const needle of forbidden) {
      assert.ok(!text.includes(needle), `${name} names ${needle}: take it from environments.json`);
    }
    // `.dev.vars.staging` in a message is fine; the plain name (a vars file with no environment) is not.
    assert.ok(!/\.dev\.vars(?![.\w])/.test(text), `${name} mentions the plain vars file`);
  }
});

test("no package.json script calls wrangler directly", () => {
  const { scripts } = JSON.parse(readFileSync(path.join(BACKEND_DIR, "package.json"), "utf8"));
  for (const [name, command] of Object.entries(scripts)) {
    assert.ok(!/wrangler/.test(command), `npm run ${name} calls wrangler: go through scripts/*.mjs, which name the environment`);
  }
});

test("every .dev.vars file is ignored but the example", () => {
  const lines = readFileSync(path.join(REPO_DIR, ".gitignore"), "utf8").split(/\r?\n/);
  assert.ok(lines.includes("backend/.dev.vars*"));
  assert.ok(lines.includes("!backend/.dev.vars.example"));
  assert.ok(
    lines.indexOf("!backend/.dev.vars.example") > lines.indexOf("backend/.dev.vars*"),
    "the exception must come after the pattern",
  );

  const inside = spawnSync("git", ["rev-parse", "--is-inside-work-tree"], { cwd: REPO_DIR, encoding: "utf8" });
  if (inside.status !== 0 || inside.stdout.trim() !== "true") {
    return; // a copy without .git (the clean CI-style run): the text assertions above are all that can be checked
  }
  const ignored = (file) => spawnSync("git", ["check-ignore", "-q", file], { cwd: REPO_DIR }).status;
  assert.equal(ignored("backend/.dev.vars"), 0);
  assert.equal(ignored("backend/.dev.vars.staging"), 0);
  assert.equal(ignored("backend/.dev.vars.production"), 0);
  assert.equal(ignored("backend/.dev.vars.example"), 1);
});

test("the example lists exactly the seven names with empty values", () => {
  const entries = readFileSync(path.join(BACKEND_DIR, ".dev.vars.example"), "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "" && !line.startsWith("#"));
  assert.deepEqual(entries.sort(), [
    "APPLE_CLIENT_ID=",
    "APPLE_KEY_ID=",
    "APPLE_PRIVATE_KEY=",
    "APPLE_TEAM_ID=",
    "DATABASE_URL=",
    "DEV_LOGIN_SECRET=",
    "JWT_SIGNING_SECRET=",
  ]);
});

test("the old example file is gone", () => {
  assert.throws(() => readFileSync(path.join(BACKEND_DIR, ".env.example")), { code: "ENOENT" });
});
