// The one build-time value the app holds (MARAUDERS_CLIENT_KEY) is the pass the app needs in order to run, and it
// travels by five hand-offs that no compiler checks, all of them plain text: the project's value (a build setting of each
// app configuration, exactly the pass), Info-Additions.plist (which turns the setting into an Info.plist key), the
// fastlane lane `build` (which passes Jenkins's value to xcodebuild as a build setting, and a setting given on the
// command line overrides the project's), the Jenkinsfile (which binds the credential in the stage that builds) and the
// app's launch (MaraudersApp must check the pass before it starts anything, and show the block screen without it). A
// slip in any one of them leaves a build that runs on the project's value instead of Jenkins's, or a gate that checks
// nothing, with every other test green, so this test reads the files and pins each hand-off, and the doc that says how
// to read the value back from a build. What it cannot show is that Jenkins really binds the credential: only a Build
// Now proves that.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import { BACKEND_DIR } from "../../scripts/lib/targets.mjs";

const REPO = path.resolve(BACKEND_DIR, "..");
const SETTING = "MARAUDERS_CLIENT_KEY";
const URL_SETTING = "MARAUDERS_API_BASE_URL";
const CREDENTIAL = "marauders-client-key";
const PASS = "run by pass";

function read(relative) {
  return readFileSync(path.join(REPO, relative), "utf8");
}

/** The `buildSettings = { ... };` blocks of a project file, each with the name of the configuration it belongs to. */
function buildSettingBlocks(pbxproj) {
  return [...pbxproj.matchAll(/buildSettings = \{\n([\s\S]*?)\n\t\t\t\};\n\t\t\tname = (.+);/g)].map((match) => ({
    name: match[2].replace(/^"(.*)"$/, "$1"),
    settings: match[1],
  }));
}

test("bothAppConfigurationsHoldThePass", () => {
  const appBlocks = buildSettingBlocks(read("Marauders-ios/Marauders.xcodeproj/project.pbxproj")).filter(
    ({ settings }) => settings.includes(`${URL_SETTING} = `),
  );
  assert.deepEqual(appBlocks.map(({ name }) => name).sort(), ["Debug-Staging", "Release-Production"]);
  for (const { name, settings } of appBlocks) {
    const value = new RegExp(`^\\t\\t\\t\\t${SETTING} = "?([^";]*)"?;$`, "m").exec(settings)?.[1];
    assert.equal(value, PASS, `${name}: the app runs only with the pass, so the project must hold exactly "${PASS}"`);
  }
});

test("theAppChecksThePassBeforeItStartsAnything", () => {
  const app = read("Marauders-ios/Marauders/App/MaraudersApp.swift");
  const init = app.slice(app.indexOf("init() {"), app.indexOf("var body: some Scene"));
  const gate = init.search(/guard ClientKey\.appMayRun\(\) else \{[^}]*\breturn\b[^}]*\}/);
  assert.notEqual(gate, -1, "init() must return early when ClientKey.appMayRun() is false");
  for (const started of [/AuthLog\.forwardToAppLog\(\)/, /InstallationSessionGuard\.bootstrap\(/, /AppDependencyContainer\./]) {
    assert.ok(init.search(started) > gate, `${started} must come after the pass check`);
  }
  assert.match(
    app,
    /if ClientKey\.appMayRun\(\)\s*\{\s*AppRootView\(\)\s*\}\s*else\s*\{\s*ClientKeyBlockedView\(\)\s*\}/,
    "the window shows the app only for the pass and the block screen otherwise",
  );
  const relaunch = app.slice(app.indexOf(".backgroundTask("));
  const check = relaunch.indexOf("ClientKey.appMayRun()");
  assert.ok(check !== -1 && check < relaunch.indexOf("awaitSystemEvents()"), "a relaunch for an upload must not start the uploader of a blocked build");
});

test("infoAdditionsHandsTheBuildSettingToInfoPlist", () => {
  assert.match(
    read("Marauders-ios/Config/Info-Additions.plist"),
    /<key>MARAUDERS_CLIENT_KEY<\/key>\s*<string>\$\(MARAUDERS_CLIENT_KEY\)<\/string>/,
  );
});

test("theFastfilePassesTheValueOnlyWhenJenkinsGaveOne", () => {
  const fastfile = read("Marauders-ios/fastlane/Fastfile");
  assert.match(fastfile, /^require "shellwords"$/m, "Shellwords.escape needs the require");
  assert.match(fastfile, /ENV\["MARAUDERS_CLIENT_KEY"\]\.to_s\.strip/, "the value is read from the environment and stripped");
  assert.match(
    fastfile,
    /xcargs <<\s*"MARAUDERS_CLIENT_KEY=#\{Shellwords\.escape\(\w+\)\}"\s+unless\s+\w+\.empty\?/,
    "the value is escaped for the shell and passed only when it is not empty",
  );
});

test("theJenkinsfileBindsTheCredentialInTheDeployStageOnly", () => {
  const jenkinsfile = read("Jenkinsfile");
  const at = jenkinsfile.indexOf("stage('Deploy to TestFlight')");
  assert.notEqual(at, -1, "the Jenkinsfile has no stage 'Deploy to TestFlight'");
  assert.ok(
    jenkinsfile.slice(at).includes(`string(credentialsId: '${CREDENTIAL}', variable: '${SETTING}')`),
    "the Deploy stage must bind the credential to the variable the Fastfile reads",
  );
  assert.equal(jenkinsfile.slice(0, at).includes(CREDENTIAL), false, "no stage before Deploy builds, so none may bind it");
});

test("docsSayWhereTheValueAppearsInLogsOnTheJenkinsMachine", () => {
  assert.ok(
    read("docs/ci-cd.md").includes("~/Library/Logs/gym"),
    "docs/ci-cd.md must say that gym keeps xcodebuild's raw log, with the value in it, where Jenkins does not mask it",
  );
});

test("docsGiveTheCredentialItsExactValue", () => {
  const row = read("docs/ci-cd.md").split("\n").find((line) => line.startsWith(`| \`${CREDENTIAL}\``));
  assert.ok(row?.includes(PASS), "the credentials table of docs/ci-cd.md must say the credential holds exactly the pass");
  const sentence = read("deployment/README.md").split("\n").find((line) => line.includes(`\`${CREDENTIAL}\``));
  assert.ok(sentence?.includes(PASS), "deployment/README.md must say the credential holds exactly the pass");
});

test("docsListTheCredentialAndTheReadBack", () => {
  const doc = read("docs/ci-cd.md");
  assert.ok(doc.includes(`\`${CREDENTIAL}\``), `docs/ci-cd.md must list the credential ${CREDENTIAL}`);
  assert.ok(
    doc.includes(`plutil -extract ${SETTING} raw`),
    "docs/ci-cd.md must say how to read the value back from a build",
  );
});

test("docsSayWhatEachWayToProveTheInjectionCosts", () => {
  const doc = read("docs/ci-cd.md");
  const start = doc.indexOf("**ทดสอบว่า Jenkins ฝังค่าจริง");
  const end = doc.indexOf("**อ่านค่ากลับจาก .ipa");
  assert.ok(start !== -1 && start < end, "docs/ci-cd.md lost the paragraph that says how to prove Jenkins injected the value");
  const paragraph = doc.slice(start, end);
  const costs = {
    TestFlight: "setting the credential to another text uploads a build that cannot open",
    "npm test": "taking the project's two lines out turns the script tests red",
    "unit test": "... and the unit test that reads the built app",
    Backend: "... and the Backend workflow on GitHub, which watches project.pbxproj",
    "npm run deploy": "... and stops a Worker deploy, which runs npm test first",
  };
  const unsaid = Object.entries(costs)
    .filter(([word]) => !paragraph.includes(word))
    .map(([word, cost]) => `${word}: ${cost}`);
  assert.deepEqual(unsaid, [], "the paragraph must say what each way to prove the injection costs");
  assert.match(paragraph, /ใส่สองบรรทัดกลับ[\s\S]*push/, "it must say to put the two lines back and push straight after the Build Now");
});
