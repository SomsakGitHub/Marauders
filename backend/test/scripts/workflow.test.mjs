// The CI workflow runs the offline backend tests on GitHub's runners and nothing else. The repository is public, so
// this test pins what keeps that safe: a read-only token, no secret of any kind, no deploy, no trigger that runs
// code from a fork with write access, and every action pinned to a commit. The workflow is read as text (the project
// has no YAML parser, and these checks need none).
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import { BACKEND_DIR } from "../../scripts/lib/targets.mjs";

const WORKFLOW_PATH = path.resolve(BACKEND_DIR, "..", ".github", "workflows", "backend.yml");

// What the agreement test (iosEnvironments.test.mjs) and the Worker read, so a change to any of them must run CI.
// APIConfiguration.plist is deleted, but a plist that comes back must trigger the run that would catch it.
const WATCHED_PATHS = [
  "backend/**",
  ".github/workflows/backend.yml",
  "Marauders-ios/Marauders.xcodeproj/project.pbxproj",
  "Marauders-ios/Config/Info-Additions.plist",
  "Marauders-ios/Marauders/APIConfiguration.plist",
];

function workflow() {
  assert.ok(existsSync(WORKFLOW_PATH), ".github/workflows/backend.yml must exist");
  return readFileSync(WORKFLOW_PATH, "utf8");
}

function escapeForRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

test("the workflow file exists and is named Backend", () => {
  assert.match(workflow(), /^name: Backend$/m);
});

test("the token is read-only", () => {
  const text = workflow();
  assert.match(text, /^permissions:\n {2}contents: read$/m);
  assert.doesNotMatch(text, /:\s*write\b/, "no permission may be write");
});

test("it holds no secret, no deploy and no trigger that hands a fork's code a token", () => {
  const text = workflow();
  for (const forbidden of [
    "secrets.",
    "pull_request_target",
    "CLOUDFLARE",
    "DATABASE_URL",
    "JWT_SIGNING_SECRET",
    "DEV_LOGIN_SECRET",
    "wrangler deploy",
    "wrangler secret",
    "npm run deploy",
    "db:migrate",
    "db:purge",
    "id-token",
  ]) {
    assert.equal(text.includes(forbidden), false, `the workflow must not contain "${forbidden}"`);
  }
});

test("every action is pinned to a full commit SHA", () => {
  const uses = workflow()
    .split("\n")
    .filter((line) => /^\s*-?\s*uses:/.test(line));
  assert.ok(uses.length >= 2, "expected at least checkout and setup-node");
  for (const line of uses) {
    assert.match(line, /uses: [\w.-]+\/[\w.-]+@[0-9a-f]{40}\b/, `not pinned to a commit: ${line.trim()}`);
  }
});

test("a newer push cancels the run it replaces", () => {
  const text = workflow();
  assert.match(text, /^concurrency:\n {2}group: backend-\$\{\{ github\.ref \}\}\n {2}cancel-in-progress: true$/m);
});

test("it runs on a push to main, on pull requests and by hand", () => {
  const text = workflow();
  assert.match(text, /^on:\n {2}push:\n {4}branches: \[main\]$/m);
  assert.match(text, /^ {2}pull_request:$/m);
  assert.match(text, /^ {2}workflow_dispatch:$/m);
});

test("a push and a pull request run it for the files the tests read, and for no others", () => {
  const text = workflow();
  const pathLists = [...text.matchAll(/^ {4}paths:\n((?: {6}- .+\n)+)/gm)].map((match) => match[1]);
  assert.equal(pathLists.length, 2, "expected a paths list under push and another under pull_request");
  for (const list of pathLists) {
    const entries = list
      .split("\n")
      .filter((line) => line.trim() !== "")
      .map((line) => line.replace(/^ {6}- /, "").replace(/^["']|["']$/g, ""));
    assert.deepEqual(entries, WATCHED_PATHS);
  }
  for (const entry of WATCHED_PATHS) {
    assert.match(text, new RegExp(`- ["']?${escapeForRegExp(entry)}["']?$`, "m"));
  }
});

test("one test job on ubuntu runs npm ci and npm test in backend/ with Node 22", () => {
  const text = workflow();
  assert.match(text, /^jobs:\n {2}test:$/m);
  assert.match(text, /^ {4}runs-on: ubuntu-latest$/m);
  assert.match(text, /^ {4}timeout-minutes: 15$/m);
  assert.match(text, /^ {4}defaults:\n {6}run:\n {8}working-directory: backend$/m);
  assert.match(text, /node-version: 22$/m);
  assert.match(text, /cache: npm$/m);
  assert.match(text, /cache-dependency-path: backend\/package-lock\.json$/m);
  assert.match(text, /^ {6}- run: npm ci$/m);
  assert.match(text, /^ {6}- run: npm test$/m);
});
