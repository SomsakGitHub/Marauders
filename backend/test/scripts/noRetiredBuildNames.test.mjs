// A scheme or a configuration that was renamed leaves "scheme not found" behind in every place that still names the old
// one: a command in a README or a CI file, a fastlane lane, a test's comment telling how to run it. A stale name breaks
// at the worst moment (a Jenkins run, a teammate following the docs). The app's scheme used to be "Marauders" and its
// configurations "Debug" and "Release"; since 2026-11-20 they are "Marauders Staging" and "Marauders Production", and
// "Debug-Staging" and "Release-Production" (docs/superpowers/specs/2026-11-20-app-environments-design.md). This test
// reads the places where such commands are written down (the README, ARCHITECTURE.md, the CI files, the docs of the
// deployment, the scripts, the comments of the tests) and fails when one still names the old scheme or an old
// configuration. iosEnvironments.test.mjs checks the project file itself.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import { BACKEND_DIR } from "../../scripts/lib/targets.mjs";

const REPO = path.resolve(BACKEND_DIR, "..");

const PLACES = [
  "README.md", "ARCHITECTURE.md", "Jenkinsfile", "docs/ci-cd.md", "deployment", ".github",
  "Marauders-ios/fastlane", "Marauders-ios/Scripts", "Marauders-ios/MaraudersTests", "Marauders-ios/MaraudersUITests",
];
const TEXT_FILE = /\.(md|mjs|js|json|ya?ml|sh|rb|swift|py|txt|toml)$|(^|\/)(Jenkinsfile|Fastfile)$/;
const SKIPPED_FOLDERS = new Set(["node_modules", ".build", "build", "vendor", ".git"]);
const RETIRED = [
  { what: 'the scheme "Marauders"', pattern: /-scheme\s+(?:"Marauders"|'Marauders'|Marauders(?![\w.-]))/ },
  { what: 'the configuration "Debug" or "Release"', pattern: /-configuration\s+(?:"(?:Debug|Release)"|'(?:Debug|Release)'|(?:Debug|Release)(?![\w.-]))/ },
  { what: 'a gym configuration "Debug" or "Release"', pattern: /\bconfiguration:\s*["'](?:Debug|Release)["']/ },
];

/** Yields the repo-relative path of every file under `entry` (a file or a folder; a missing entry yields nothing) that TEXT_FILE accepts, skipping SKIPPED_FOLDERS. */
function* textFiles(entry) {
  const full = path.join(REPO, entry);
  if (!existsSync(full)) return;
  if (statSync(full).isFile()) {
    if (TEXT_FILE.test(entry)) yield entry;
    return;
  }
  for (const name of readdirSync(full)) {
    if (!SKIPPED_FOLDERS.has(name)) yield* textFiles(path.join(entry, name));
  }
}

function retiredNames(line) {
  return RETIRED.filter(({ pattern }) => pattern.test(line)).map(({ what }) => what);
}

test("the scan flags the retired names and accepts the new ones", () => {
  for (const line of [
    "xcodebuild test -scheme Marauders -destination x", "(`xcodebuild test -scheme Marauders`)", '-scheme "Marauders"',
    "-scheme Marauders \\", "-scheme Marauders Staging", "-configuration Release -destination x", '-configuration "Debug"',
    'gym(configuration: "Release")',
  ]) {
    assert.notEqual(retiredNames(line).length, 0, line);
  }
  for (const line of [
    '-scheme "Marauders Staging"', "-scheme 'Marauders Production'", '"-scheme #{TEST_SCHEME}"', "-configuration Release-Production",
    '-configuration "Debug-Staging"', "configuration: RELEASE_CONFIGURATION", "-only-testing:MaraudersTests", "-project Marauders.xcodeproj",
  ]) {
    assert.deepEqual(retiredNames(line), [], line);
  }
});

test("no written-down command names a retired scheme or configuration", () => {
  const violations = [];
  for (const place of PLACES) {
    for (const file of textFiles(place)) {
      readFileSync(path.join(REPO, file), "utf8").split("\n").forEach((line, index) => {
        for (const what of retiredNames(line)) violations.push(`${file}:${index + 1}: ${what}: ${line.trim().slice(0, 100)}`);
      });
    }
  }
  assert.deepEqual(violations, []);
});
