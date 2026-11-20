// The app and the Worker must agree on which URL belongs to which environment. The app's URL lives in the Xcode
// project (a build setting per configuration, handed to Info.plist by Config/Info-Additions.plist); the Workers' URLs
// live in backend/environments.json. This test reads both and fails when they drift apart: the Production build
// (configuration Release-Production) must talk to production, the Staging build (configuration Debug-Staging) to the
// environment DEBUG_ENVIRONMENT names (and the dev login must read that environment's vars file), and nothing else may
// carry the URL (the bundled APIConfiguration.plist used to). It also checks what separates the two builds: the two
// configurations in each of the project's four lists, the two shared schemes and what each action of them builds, the
// Run Script phases and the guard's wiring (docs/superpowers/specs/2026-11-20-app-environments-design.md).
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import { BACKEND_DIR, loadEnvironments } from "../../scripts/lib/targets.mjs";

const IOS_DIR = path.resolve(BACKEND_DIR, "..", "Marauders-ios");
const PBXPROJ = path.join(IOS_DIR, "Marauders.xcodeproj", "project.pbxproj");
const INFO_ADDITIONS = path.join(IOS_DIR, "Config", "Info-Additions.plist");
const BUNDLED_PLIST = path.join(IOS_DIR, "Marauders", "APIConfiguration.plist");
const DEV_LOGIN_SOURCE = path.join(IOS_DIR, "Marauders", "Shared", "Configuration", "DevLogin.swift");
const GUARD_SCRIPT = path.join(IOS_DIR, "Scripts", "check-release-config.sh");
const APP_BUNDLE_ID = "com.somsak.Marauders";
const URL_SETTING = "MARAUDERS_API_BASE_URL";
const SCHEMES_DIR = path.join(IOS_DIR, "Marauders.xcodeproj", "xcshareddata", "xcschemes");
const STAGING_CONFIGURATION = "Debug-Staging";
const PRODUCTION_CONFIGURATION = "Release-Production";
const STAGING_SCHEME = "Marauders Staging";
const PRODUCTION_SCHEME = "Marauders Production";

// The environment the app's Staging builds (configuration Debug-Staging, the DEBUG flag) talk to. ADR 010 (decision of
// 2026-11-20): there is one backend, production, until the owner provisions staging, so Staging uses production too.
// To point Staging at staging, change this constant, the Debug-Staging build setting MARAUDERS_API_BASE_URL and the
// vars file DevLogin reads (the tests below check all three), and create staging's resources first
// (docs/superpowers/plans/2026-11-19-environments.md, Task 13 steps 3 to 6).
const DEBUG_ENVIRONMENT = "production";

function unquote(value) {
  return value.length >= 2 && value.startsWith('"') && value.endsWith('"') ? value.slice(1, -1) : value;
}

/** The `XCBuildConfiguration` blocks of a project file, as `{ name, settings }` (a setting's value without quotes). */
function parseBuildConfigurations(pbxproj) {
  const section = /\/\* Begin XCBuildConfiguration section \*\/([\s\S]*?)\/\* End XCBuildConfiguration section \*\//.exec(pbxproj);
  if (!section) {
    return [];
  }
  const configurations = [];
  for (const block of section[1].matchAll(/^\t\t[0-9A-F]{24} \/\* .+? \*\/ = \{\n([\s\S]*?)^\t\t\};$/gm)) {
    const body = block[1];
    const name = /^\t\t\tname = (.+);$/m.exec(body)?.[1];
    const buildSettings = /^\t\t\tbuildSettings = \{\n([\s\S]*?)^\t\t\t\};$/m.exec(body)?.[1] ?? "";
    const settings = {};
    for (const line of buildSettings.matchAll(/^\t\t\t\t(\S+) = (.+);$/gm)) {
      settings[line[1]] = unquote(line[2]);
    }
    configurations.push({ name: name === undefined ? undefined : unquote(name), settings });
  }
  return configurations;
}

/** The configuration of the app target (the one with the app's bundle id) with the given name. */
function appConfiguration(name) {
  const matches = parseBuildConfigurations(readFileSync(PBXPROJ, "utf8")).filter(
    (configuration) => configuration.name === name && configuration.settings.PRODUCT_BUNDLE_IDENTIFIER === APP_BUNDLE_ID,
  );
  assert.equal(matches.length, 1, `expected exactly one ${name} configuration for ${APP_BUNDLE_ID}, found ${matches.length}`);
  return matches[0];
}

test("parseBuildConfigurations reads the names and the one-line settings of each block", () => {
  const fixture = [
    "/* Begin XCBuildConfiguration section */",
    "\t\t06BC2C4E3075A7FC0064F635 /* Debug */ = {",
    "\t\t\tisa = XCBuildConfiguration;",
    "\t\t\tbuildSettings = {",
    '\t\t\t\tMARAUDERS_API_BASE_URL = "https://a.example";',
    "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (",
    '\t\t\t\t\t"$(inherited)",',
    "\t\t\t\t);",
    "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.somsak.Marauders;",
    "\t\t\t};",
    "\t\t\tname = Debug;",
    "\t\t};",
    "\t\t06BC2C4F3075A7FC0064F635 /* Release */ = {",
    "\t\t\tisa = XCBuildConfiguration;",
    "\t\t\tbuildSettings = {",
    "\t\t\t\tSDKROOT = iphoneos;",
    "\t\t\t};",
    "\t\t\tname = Release;",
    "\t\t};",
    "/* End XCBuildConfiguration section */",
  ].join("\n");
  assert.deepEqual(parseBuildConfigurations(fixture), [
    {
      name: "Debug",
      settings: { MARAUDERS_API_BASE_URL: "https://a.example", PRODUCT_BUNDLE_IDENTIFIER: "com.somsak.Marauders" },
    },
    { name: "Release", settings: { SDKROOT: "iphoneos" } },
  ]);
  assert.deepEqual(parseBuildConfigurations("nothing to see here"), []);
});

test("the Staging build of the app is built for the environment the Staging builds use", () => {
  assert.equal(appConfiguration(STAGING_CONFIGURATION).settings[URL_SETTING], loadEnvironments()[DEBUG_ENVIRONMENT].url);
});

test("the dev login reads the vars file of the environment the Staging builds use", () => {
  const source = readFileSync(DEV_LOGIN_SOURCE, "utf8");
  const files = [...source.matchAll(/"backend\/(\.dev\.vars\.[a-z]+)"/g)].map((match) => match[1]);
  assert.deepEqual(files, [loadEnvironments()[DEBUG_ENVIRONMENT].varsFile]);
});

test("the Production build of the app is built for production", () => {
  assert.equal(appConfiguration(PRODUCTION_CONFIGURATION).settings[URL_SETTING], loadEnvironments().production.url);
});

test("no build setting still tries to reach Info.plist through an INFOPLIST_KEY_ name Xcode ignores", () => {
  assert.equal(readFileSync(PBXPROJ, "utf8").includes(`INFOPLIST_KEY_${URL_SETTING}`), false);
});

test("Info-Additions.plist hands the build setting to Info.plist", () => {
  const plist = readFileSync(INFO_ADDITIONS, "utf8");
  assert.match(plist, new RegExp(`<key>${URL_SETTING}</key>\\s*<string>\\$\\(${URL_SETTING}\\)</string>`));
});

test("the bundled APIConfiguration.plist, a second place for the URL, is gone", () => {
  assert.equal(existsSync(BUNDLED_PLIST), false, "Marauders-ios/Marauders/APIConfiguration.plist must be deleted");
});

/** What each action of a scheme builds with, e.g. { TestAction: "Debug-Staging", ... }, and the scheme's text. */
function schemeConfigurations(schemeName) {
  const xml = readFileSync(path.join(SCHEMES_DIR, `${schemeName}.xcscheme`), "utf8");
  const actions = {};
  for (const match of xml.matchAll(/<(TestAction|LaunchAction|AnalyzeAction|ProfileAction|ArchiveAction)\s+buildConfiguration = "([^"]+)"/g)) {
    actions[match[1]] = match[2];
  }
  return { xml, actions };
}

test("the project has exactly two configurations, Debug-Staging and Release-Production, in each of its four lists", () => {
  const names = parseBuildConfigurations(readFileSync(PBXPROJ, "utf8")).map((configuration) => configuration.name);
  assert.deepEqual(names.sort(), [...Array(4).fill(STAGING_CONFIGURATION), ...Array(4).fill(PRODUCTION_CONFIGURATION)]);
});

test("a build that names no configuration gets Production, the default of every list", () => {
  const defaults = [...readFileSync(PBXPROJ, "utf8").matchAll(/^\t\t\tdefaultConfigurationName = (.+);$/gm)].map((match) => unquote(match[1]));
  assert.deepEqual(defaults, Array(4).fill(PRODUCTION_CONFIGURATION));
});

test("the shared schemes are exactly Marauders Staging and Marauders Production", () => {
  const files = readdirSync(SCHEMES_DIR).filter((name) => name.endsWith(".xcscheme")).sort();
  assert.deepEqual(files, [`${PRODUCTION_SCHEME}.xcscheme`, `${STAGING_SCHEME}.xcscheme`]);
});

test("Marauders Staging runs, tests and analyzes as Staging, and profiles and archives as Production", () => {
  const { actions, xml } = schemeConfigurations(STAGING_SCHEME);
  assert.deepEqual(actions, {
    TestAction: STAGING_CONFIGURATION,
    LaunchAction: STAGING_CONFIGURATION,
    AnalyzeAction: STAGING_CONFIGURATION,
    ProfileAction: PRODUCTION_CONFIGURATION,
    ArchiveAction: PRODUCTION_CONFIGURATION,
  });
  assert.match(xml, /BuildableName = "MaraudersTests\.xctest"/);
  assert.match(xml, /BuildableName = "MaraudersUITests\.xctest"/);
  assert.match(xml, /argument = "-AppleLanguages \(en\)"/);
  assert.match(xml, /argument = "-AppleLocale en_US"/);
});

test("Marauders Production builds every action as Production and has no test target", () => {
  const { actions, xml } = schemeConfigurations(PRODUCTION_SCHEME);
  assert.deepEqual(actions, {
    TestAction: PRODUCTION_CONFIGURATION,
    LaunchAction: PRODUCTION_CONFIGURATION,
    AnalyzeAction: PRODUCTION_CONFIGURATION,
    ProfileAction: PRODUCTION_CONFIGURATION,
    ArchiveAction: PRODUCTION_CONFIGURATION,
  });
  assert.equal(xml.includes("<TestableReference"), false);
  assert.match(xml, /BuildableName = "Marauders\.app"/);
});

test("the Run Script phases that look at the configuration look at Release-Production, never at Release", () => {
  const scripts = [...readFileSync(PBXPROJ, "utf8").matchAll(/^\t\t\tshellScript = (".*");$/gm)]
    .map((match) => match[1])
    .filter((script) => script.includes("$CONFIGURATION"));
  assert.equal(scripts.length, 3);
  for (const script of scripts) {
    assert.ok(script.includes(`\\"${PRODUCTION_CONFIGURATION}\\"`), script);
    assert.equal(script.includes('\\"Release\\"'), false, script);
  }
});

/** The `shellScript` of the Run Script phase with this name, as the project file spells it (its quotes still escaped). */
function runScriptPhase(name) {
  const phase = new RegExp(`/\\* Run Script ${name} \\*/ = \\{([\\s\\S]*?)\\n\\t\\t\\};`).exec(readFileSync(PBXPROJ, "utf8"))?.[1] ?? "";
  return /^\t\t\tshellScript = (".*");$/m.exec(phase)?.[1] ?? "";
}

// The test above only looks for the name Release-Production. A flipped operator keeps the name and turns the guard
// off for Production (and on for Staging), with every test green: so the operator and the order are pinned too.
test("the Run Script phases gate on Production in the right direction, before they do their work", () => {
  const runsOnlyForProduction = `if [ \\"$CONFIGURATION\\" != \\"${PRODUCTION_CONFIGURATION}\\" ]; then exit 0; fi`;
  const skipsProduction = `if [ \\"$CONFIGURATION\\" = \\"${PRODUCTION_CONFIGURATION}\\" ]; then exit 0; fi`;
  const phases = [
    { name: "release config check", gate: runsOnlyForProduction, otherGate: skipsProduction, work: 'sh \\"$SRCROOT/Scripts/check-release-config.sh\\"' },
    { name: "lint", gate: skipsProduction, otherGate: runsOnlyForProduction, work: "xcrun swift-format" },
    { name: "layer check", gate: skipsProduction, otherGate: runsOnlyForProduction, work: 'sh \\"$SRCROOT/Scripts/check-layers.sh\\"' },
  ];
  for (const { name, gate, otherGate, work } of phases) {
    const script = runScriptPhase(name);
    assert.ok(script.length > 0, `there is no Run Script phase named "${name}"`);
    assert.ok(script.includes(gate), `${name}: the phase must start with ${gate}`);
    assert.equal(script.includes(otherGate), false, `${name}: the phase must not hold ${otherGate}`);
    assert.ok(script.includes(work), `${name}: the phase must still run ${work}`);
    assert.ok(script.indexOf(gate) < script.indexOf(work), `${name}: the gate must come before the work`);
  }
});

/** The text of every `.swift` file of the app and of the local packages (build folders left out). */
function swiftSources() {
  return ["Marauders", "Packages"].flatMap((folder) =>
    readdirSync(path.join(IOS_DIR, folder), { recursive: true })
      .filter((file) => file.endsWith(".swift") && !file.split("/").includes(".build"))
      .map((file) => readFileSync(path.join(IOS_DIR, folder, file), "utf8")),
  );
}

test("every Debug-only type the Production guard looks for is still declared in the Swift sources", () => {
  const types = /^DEBUG_ONLY_TYPES="([^"]+)"$/m.exec(readFileSync(GUARD_SCRIPT, "utf8"))?.[1]?.split(" ");
  assert.ok(types && types.length >= 2, "the guard must name its Debug-only types in DEBUG_ONLY_TYPES");
  const sources = swiftSources();
  for (const type of types) {
    const declared = new RegExp(`\\b(?:struct|class|enum|actor|protocol)\\s+${type}\\b`);
    assert.ok(sources.some((source) => declared.test(source)), `${type} is declared nowhere: the guard would look for nothing`);
  }
});

test("the guard's Run Script phase hands it the built executable and waits for that file", () => {
  const phase = /\/\* Run Script release config check \*\/ = \{([\s\S]*?)\n\t\t\};/.exec(readFileSync(PBXPROJ, "utf8"))?.[1] ?? "";
  assert.match(phase, /--executable \\"\$TARGET_BUILD_DIR\/\$EXECUTABLE_PATH\\"/);
  assert.match(phase, /"\$\(TARGET_BUILD_DIR\)\/\$\(EXECUTABLE_PATH\)",/);
});
