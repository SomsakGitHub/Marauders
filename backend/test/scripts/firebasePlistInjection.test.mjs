// The force-update gate reads its minimum build from Firebase Remote Config (docs/adr/012-force-update.md), and that
// rests on hand-offs that no compiler checks, all of them plain text: the SDK is added for two products only and
// touched by one file (the app must never import it anywhere else), the plist that starts it is kept out of git and
// reaches a shipped build only through Jenkins, the fastlane lanes and the Jenkinsfile, and the docs say so. A slip in
// any one of them leaves a build whose gate is silently unarmed, or an SDK that reaches code it should not, with every
// other test green, so this test reads the files and pins each hand-off. What it cannot show is that Jenkins really
// binds the credential: only a Build Now proves that, and the read-back of the plist from the .ipa that docs/ci-cd.md
// describes.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { BACKEND_DIR } from "../../scripts/lib/targets.mjs";

const REPO = path.resolve(BACKEND_DIR, "..");
const APP_SOURCES = "Marauders-ios/Marauders";
const SOURCE_FILE = `${APP_SOURCES}/Data/Repositories/FirebaseRemoteConfigSource.swift`;
const PLIST_FILE = `${APP_SOURCES}/GoogleService-Info.plist`;
const CREDENTIAL = "marauders-firebase-plist";
const VARIABLE = "FIREBASE_PLIST_PATH";

function read(relative) {
  return readFileSync(path.join(REPO, relative), "utf8");
}

/** The text of `lane :<name> do ... end` in a Fastfile: from its first line to the `desc` of the next lane (or the end). */
function laneBlock(fastfile, name) {
  const start = fastfile.indexOf(`lane :${name} do`);
  assert.notEqual(start, -1, `the Fastfile has no lane :${name}`);
  const rest = fastfile.slice(start + 1);
  const ends = ["\n  desc ", "\n  lane :", "\nend"].map((marker) => rest.indexOf(marker)).filter((index) => index !== -1);
  return rest.slice(0, Math.min(...ends));
}

/** Every Swift file under `directory` (relative to the repository), as a repository-relative path with `/`. */
function swiftFiles(directory) {
  return readdirSync(path.join(REPO, directory), { recursive: true })
    .filter((name) => name.endsWith(".swift"))
    .map((name) => `${directory}/${name.split(path.sep).join("/")}`);
}

test("onlyTheSourceFileImportsFirebase", () => {
  const importing = swiftFiles(APP_SOURCES).filter((file) => /^\s*import Firebase/m.test(read(file)));
  assert.deepEqual(importing, [SOURCE_FILE], "only FirebaseRemoteConfigSource.swift may import Firebase");
  const source = read(SOURCE_FILE);
  for (const needle of [
    "FirebaseApp.configure(options:",
    "@concurrent",
    "minimumFetchInterval = 3600",
    "fetchTimeout = 10",
    '"minimum_build"',
    '"update_url"',
  ]) {
    assert.ok(source.includes(needle), `FirebaseRemoteConfigSource.swift must hold ${needle}`);
  }
});

test("theSourceNeverAsksTheSdkWhetherItIsStarted", () => {
  // While no app is configured each of these logs an error line ("The default Firebase app has not yet been configured.
  // Add FirebaseApp.configure() …", I-COR000003 and its siblings). That is the normal answer on a Run without a plist and
  // at the first ask of every launch, so the console would show an SDK error next to a gate that is working as designed
  // (seen on the simulator on 2026-11-21). The source keeps its own answer to "is it started?" instead.
  const source = read(SOURCE_FILE);
  for (const call of ["FirebaseApp.app(", "FirebaseApp.allApps"]) {
    assert.ok(!source.includes(call), `FirebaseRemoteConfigSource.swift must not call ${call}: it logs an SDK error while no app is configured`);
  }
  assert.match(source, /Mutex[(<]/, "the answer is kept behind a lock, so two asks at once start the SDK once");
});

// FIRApp.h says of configure(options:): "This method should be called from the main thread", and it is the one call whose
// failure Swift cannot catch (an Objective-C exception), so the source starts the SDK in a hop to the main actor and
// keeps the plist read, the check and the wait for the network off it.
test("theSdkIsStartedOnTheMainActor", () => {
  const source = read(SOURCE_FILE);
  const hop = source.indexOf("MainActor.run");
  const start = source.indexOf("FirebaseApp.configure(");
  assert.notEqual(hop, -1, "FirebaseRemoteConfigSource.swift must hop to the main actor (MainActor.run) to start the SDK");
  assert.notEqual(start, -1, "FirebaseRemoteConfigSource.swift must start the SDK with FirebaseApp.configure(options:)");
  assert.ok(hop < start, "FirebaseApp.configure must be called inside the MainActor.run, which comes before it in the file");
});

// The SDK asks Google at most once an hour (minimumFetchInterval) and answers from what it saved in between, and both end
// in a success, so `config refreshed: minimumBuild=5` alone cannot say whether Google just said 5 or the SDK still holds the
// 5 it got before the owner published 0 (the owner met exactly that on 2026-11-22). The SDK's own lastFetchTime moves only
// when Google answers (RCNConfigFetch.m and RCNConfigSettings.m of 13.2.0), so the source reads it before and after
// fetchAndActivate() and hands both to RemoteConfigOrigin.judge, and the repository puts the verdict in its log line.
test("theSourceSaysWhetherGoogleWasAskedOrTheSdkAnsweredFromItsSavedValues", () => {
  const source = read(SOURCE_FILE);
  const body = source.slice(source.indexOf("func fetch()"), source.indexOf("func startFirebaseIfNeeded"));
  const fetch = body.indexOf("fetchAndActivate()");
  assert.notEqual(fetch, -1, "fetch() must call fetchAndActivate()");
  const first = body.indexOf("lastFetchTime");
  const last = body.lastIndexOf("lastFetchTime");
  assert.ok(first !== -1 && first < fetch && last > fetch, "fetch() must read lastFetchTime before and after fetchAndActivate()");
  assert.ok(body.includes("RemoteConfigOrigin.judge("), "fetch() must hand both times to RemoteConfigOrigin.judge");
  const repository = read(`${APP_SOURCES}/Data/Repositories/FirebaseAppConfigRepository.swift`);
  assert.match(repository, /config refreshed: minimumBuild=[^"]*origin/, "the repository must put the origin in its config refreshed line");
});

// The pins of this file read files that are not under backend/, and a workflow that does not start when they change lets
// a commit drop a hand-off (the plist check of lane :beta, the Jenkins binding, the ignore rule) with every check green.
const WATCHED_BY_THE_PINS = [
  "Jenkinsfile",
  ".gitignore",
  "Marauders-ios/fastlane/Fastfile",
  "Marauders-ios/Marauders/**",
  "README.md",
  "ARCHITECTURE.md",
  "deployment/README.md",
  "docs/ci-cd.md",
  "docs/adr/**",
];

test("theWorkflowThatRunsThesePinsWatchesTheFilesTheyPin", () => {
  const workflow = read(".github/workflows/backend.yml");
  const push = workflow.slice(workflow.indexOf("\n  push:"), workflow.indexOf("\n  pull_request:"));
  const pullRequest = workflow.slice(workflow.indexOf("\n  pull_request:"), workflow.indexOf("\n  workflow_dispatch:"));
  for (const [trigger, block] of [
    ["push", push],
    ["pull_request", pullRequest],
  ]) {
    assert.ok(block.includes("paths:"), `the ${trigger} trigger of backend.yml must be limited by paths`);
    for (const watched of WATCHED_BY_THE_PINS) {
      assert.ok(
        block.includes(`- "${watched}"`),
        `the ${trigger} trigger of backend.yml must watch ${watched}: firebasePlistInjection.test.mjs pins it, and the pin would not run when it changes`,
      );
    }
  }
});

test("theSdkIsAddedForTheTwoProductsOnly", () => {
  const project = read("Marauders-ios/Marauders.xcodeproj/project.pbxproj");
  assert.match(
    project,
    /XCRemoteSwiftPackageReference "firebase-ios-sdk" \*\/ = \{\s*isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "https:\/\/github\.com\/firebase\/firebase-ios-sdk";\s*requirement = \{\s*kind = upToNextMajorVersion;\s*minimumVersion = 13\.2\.0;\s*\};/,
    "firebase-ios-sdk is added as up to next major from 13.2.0",
  );
  const products = [...new Set([...project.matchAll(/productName = (Firebase\w*);/g)].map((match) => match[1]))].sort();
  assert.deepEqual(products, ["FirebaseCore", "FirebaseRemoteConfig"], "two products only, no Analytics");
});

test("thePlistIsKeptOutOfGit", () => {
  const rules = read(".gitignore")
    .split("\n")
    .map((line) => line.trim());
  assert.ok(rules.includes(PLIST_FILE), `.gitignore must hold the line ${PLIST_FILE}: the repository is public`);
});

test("theBuildLaneCopiesThePlistWhenJenkinsGivesIt", () => {
  const fastfile = read("Marauders-ios/fastlane/Fastfile");
  const start = fastfile.indexOf("def place_firebase_plist");
  assert.notEqual(start, -1, "the Fastfile must define place_firebase_plist");
  const helper = fastfile.slice(start, fastfile.indexOf("\nend\n", start));
  assert.ok(helper.includes(`ENV["${VARIABLE}"]`), `the helper must read ${VARIABLE}, the variable the Jenkinsfile binds`);
  assert.ok(helper.includes("GoogleService-Info.plist"), "the helper must copy the file under the name the app looks for");
  assert.match(helper, /\.empty\?/, "a run without the variable (this Mac) must touch nothing");
  const build = laneBlock(fastfile, "build");
  const place = build.indexOf("place_firebase_plist");
  assert.notEqual(place, -1, "lane :build must call place_firebase_plist");
  assert.ok(place < build.indexOf("gym("), "the plist must be in place before gym archives the app");
});

/**
 * Runs the Fastfile's own `place_firebase_plist` (its text, cut out of the file) in Ruby against a scratch app folder,
 * the way the `beta` lane does: twice in a row, once for the lane and once more through `lane :build`. `source` is the
 * value of FIREBASE_PLIST_PATH, or undefined for a run without the variable (this Mac).
 */
function placePlist(root, source) {
  const fastfile = read("Marauders-ios/fastlane/Fastfile");
  const start = fastfile.indexOf("def place_firebase_plist");
  assert.notEqual(start, -1, "the Fastfile must define place_firebase_plist");
  const helper = fastfile.slice(start, fastfile.indexOf("\nend\n", start) + "\nend\n".length);
  const env = { ...process.env };
  delete env[VARIABLE];
  if (source !== undefined) {
    env[VARIABLE] = source;
  }
  const script = `PROJECT_ROOT = ARGV[0]\n${helper}\nplace_firebase_plist\nplace_firebase_plist\n`;
  execFileSync("ruby", ["-rfileutils", "-e", script, root], { env, stdio: "pipe" });
}

/** A scratch app folder with a Marauders/ folder, and files to hand over; removed when `body` is over. */
function inScratchFolder(body) {
  const folder = mkdtempSync(path.join(tmpdir(), "place-firebase-plist-"));
  try {
    const root = path.join(folder, "app");
    mkdirSync(path.join(root, "Marauders"), { recursive: true });
    const given = (name, text) => {
      const file = path.join(folder, name);
      writeFileSync(file, text);
      chmodSync(file, 0o400);
      return file;
    };
    body({ root, target: path.join(root, "Marauders", "GoogleService-Info.plist"), given });
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
}

// Jenkins writes a file credential read-only (mode 0400), and `lane :beta` places the plist twice, once itself and once
// through `lane :build`: a copy that is read-only must not stop the second one, or no TestFlight build would ever get past
// the lane's first minute. A plist already in the folder must stay when there is no variable, and the file the variable
// names must never be lost, even when it is the file in the folder.
test("placeFirebasePlistSurvivesAReadOnlyCredentialAndTwoCopies", () => {
  inScratchFolder(({ root, target, given }) => {
    placePlist(root, given("first.plist", "first"));
    assert.equal(readFileSync(target, "utf8"), "first", "the file the variable names must be copied under the name the app looks for");

    placePlist(root, given("second.plist", "second"));
    assert.equal(readFileSync(target, "utf8"), "second", "a later credential value must replace the earlier copy");
  });
});

test("placeFirebasePlistTouchesNothingWithoutTheVariable", () => {
  inScratchFolder(({ root, target }) => {
    placePlist(root, undefined);
    assert.throws(() => readFileSync(target), "no variable means no file is made");

    writeFileSync(target, "the owner's own");
    placePlist(root, undefined);
    assert.equal(readFileSync(target, "utf8"), "the owner's own", "a plist already in the folder stays");
    placePlist(root, "  ");
    assert.equal(readFileSync(target, "utf8"), "the owner's own", "a blank variable is no variable");
  });
});

test("placeFirebasePlistNeverLosesTheFileTheVariableNamesInTheFolder", () => {
  inScratchFolder(({ root, target }) => {
    writeFileSync(target, "the owner's own");
    chmodSync(target, 0o400);
    placePlist(root, target);
    assert.equal(readFileSync(target, "utf8"), "the owner's own", "a variable that names the file in the folder changes nothing");
  });
});

test("placeFirebasePlistKeepsTheFoldersPlistWhenTheVariableNamesAFileThatIsNotThere", () => {
  inScratchFolder(({ root, target }) => {
    writeFileSync(target, "the owner's own");
    assert.throws(() => placePlist(root, path.join(root, "no-such-credential.plist")), "a source that cannot be read stops the lane");
    assert.equal(readFileSync(target, "utf8"), "the owner's own", "the plist in the folder must not be lost to a bad variable");
    assert.deepEqual(readdirSync(path.join(root, "Marauders")), ["GoogleService-Info.plist"], "no half-made copy is left behind");
  });
});

test("theBetaLaneChecksThePlistBeforeItBuilds", () => {
  const beta = laneBlock(read("Marauders-ios/fastlane/Fastfile"), "beta");
  const place = beta.indexOf("place_firebase_plist");
  const check = beta.indexOf("check-firebase-plist.sh");
  assert.ok(place !== -1 && place < check, "lane :beta must place the plist and then check it");
  const identifier = beta.indexOf("APP_IDENTIFIER", check);
  const build = beta.search(/^\s*build\s*$/m);
  assert.ok(identifier !== -1, "the check must be given the app's bundle id (APP_IDENTIFIER)");
  assert.ok(build !== -1 && identifier < build, "the check must come before the lane builds");
});

test("jenkinsBindsThePlistWhereTheAppIsBuilt", () => {
  const jenkinsfile = read("Jenkinsfile");
  const at = jenkinsfile.indexOf("stage('Deploy to TestFlight')");
  assert.notEqual(at, -1, "the Jenkinsfile has no stage 'Deploy to TestFlight'");
  assert.ok(
    jenkinsfile.slice(at).includes(`file(credentialsId: '${CREDENTIAL}', variable: '${VARIABLE}')`),
    "the Deploy stage must bind the file credential to the variable the Fastfile reads",
  );
  assert.equal(jenkinsfile.slice(0, at).includes(CREDENTIAL), false, "no stage before Deploy builds, so none may bind it");
});

test("adrTwelveIsAboutFirebaseRemoteConfig", () => {
  const adr = read("docs/adr/012-force-update.md");
  for (const needle of ["Firebase Remote Config", "minimum_build", "update_url", "GoogleService-Info.plist"]) {
    assert.ok(adr.includes(needle), `ADR-012 must name ${needle}`);
  }
  const row = read("docs/adr/README.md")
    .split("\n")
    .find((line) => line.includes("(012-force-update.md)"));
  assert.ok(row?.includes("Firebase"), "the index row of ADR-012 must say that the minimum comes from Firebase");
});

test("noDocSaysTheWorkerServesTheMinimum", () => {
  for (const file of ["README.md", "ARCHITECTURE.md", "deployment/README.md", "docs/ci-cd.md"]) {
    const text = read(file);
    for (const gone of ["/v1/config", "MINIMUM_BUILD", "UPDATE_URL", "appConfig.ts"]) {
      assert.equal(text.includes(gone), false, `${file} still names ${gone}: the route is gone (ADR-012 keeps it as an alternative)`);
    }
  }
});

test("theDocsNameWhatTheyMustSay", () => {
  const mustName = {
    "README.md": ["GoogleService-Info.plist", "check-firebase-plist.sh"],
    "ARCHITECTURE.md": [
      "FirebaseRemoteConfigSource",
      "FirebasePlistCheckTests",
      "FirebaseAppConfigRepositoryTests",
      "check-firebase-plist-tests.sh",
      "firebasePlistInjection.test.mjs",
    ],
    "deployment/README.md": ["minimum_build", "update_url"],
  };
  for (const [file, needles] of Object.entries(mustName)) {
    const text = read(file);
    for (const needle of needles) {
      assert.ok(text.includes(needle), `${file} must name ${needle}`);
    }
  }
});

test("docsListThePlistCredentialAndItsReadBack", () => {
  const doc = read("docs/ci-cd.md");
  const row = doc.split("\n").find((line) => line.startsWith(`| \`${CREDENTIAL}\``));
  assert.ok(row, `the credentials table of docs/ci-cd.md must have a row for ${CREDENTIAL}`);
  assert.ok(row.includes(VARIABLE), `that row must say that Jenkins hands the file over as ${VARIABLE}`);
  assert.ok(
    doc.includes("Payload/Marauders.app/GoogleService-Info.plist"),
    "docs/ci-cd.md must say how to read the plist back from the .ipa, as it does for the client key",
  );
});
