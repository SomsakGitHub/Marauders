// Tests of backend/scripts/lib/targets.mjs and backend/environments.json: the one table of environments and
// the helper every backend script uses to say which environment it touches.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import util from "node:util";

import {
  BACKEND_DIR,
  UsageError,
  banner,
  confirm,
  databaseIdentity,
  describeDatabase,
  formatCliError,
  loadEnvironments,
  loadVars,
  parseCli,
} from "../../scripts/lib/targets.mjs";

const SECRET_URL = "postgres://alice:s3cret@ep-x-pooler.eu-west-2.aws.neon.tech/neondb?sslmode=require";
const FIELDS = ["bucket", "confirm", "devLogin", "rateLimitNamespace", "url", "varsFile", "worker", "wranglerEnv"];

function scratchDir(t) {
  const dir = mkdtempSync(path.join(tmpdir(), "targets-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test("the table holds staging and production with every field", () => {
  const table = loadEnvironments();
  assert.deepEqual(Object.keys(table).sort(), ["production", "staging"]);
  for (const [name, config] of Object.entries(table)) {
    assert.deepEqual(Object.keys(config).sort(), FIELDS, name);
    assert.match(config.url, /^https:\/\/[a-z0-9-]+\.js6ctz7gtj\.workers\.dev$/, name);
  }
  assert.deepEqual(table.production, {
    wranglerEnv: "",
    worker: "marauders-api",
    url: "https://marauders-api.js6ctz7gtj.workers.dev",
    bucket: "marauders-videos",
    varsFile: ".dev.vars.production",
    devLogin: true,
    rateLimitNamespace: "1001",
    confirm: { write: "production", purge: "purge production" },
  });
  assert.deepEqual(table.staging, {
    wranglerEnv: "staging",
    worker: "marauders-api-staging",
    url: "https://marauders-api-staging.js6ctz7gtj.workers.dev",
    bucket: "marauders-videos-staging",
    varsFile: ".dev.vars.staging",
    devLogin: true,
    rateLimitNamespace: "1002",
    confirm: { write: null, purge: "purge staging" },
  });
  for (const field of ["url", "worker", "bucket", "varsFile", "rateLimitNamespace"]) {
    assert.notEqual(table.staging[field], table.production[field], `${field} must differ between environments`);
  }
});

test("plutil reads the production URL from the table", { skip: process.platform !== "darwin" }, () => {
  // The Release guard (Marauders-ios/Scripts/check-release-config.sh) reads the table this way.
  const url = execFileSync(
    "plutil",
    ["-extract", "production.url", "raw", "-o", "-", path.join(BACKEND_DIR, "environments.json")],
    { encoding: "utf8" },
  ).trim();
  assert.equal(url, loadEnvironments().production.url);
});

test("parseCli needs a known --env and names the allowed values", () => {
  assert.throws(
    () => parseCli([]),
    (error) => error instanceof UsageError && error.message.includes("--env") && error.message.includes("staging, production"),
  );
  assert.throws(
    () => parseCli(["--env", "qa"]),
    (error) => error instanceof UsageError && error.message.includes("qa") && error.message.includes("staging, production"),
  );
  assert.throws(() => parseCli(["--env"]), UsageError);
});

test("parseCli reads --env in both spellings and returns that environment's config", () => {
  for (const argv of [["--env", "staging"], ["--env=staging"]]) {
    const parsed = parseCli(argv);
    assert.equal(parsed.name, "staging");
    assert.equal(parsed.config.worker, "marauders-api-staging");
    assert.deepEqual(parsed.positionals, []);
  }
});

test("parseCli passes --confirm and the caller's own options through", () => {
  const parsed = parseCli(
    ["--env", "production", "--confirm", "production", "--dry-run"],
    { "dry-run": { type: "boolean" } },
  );
  assert.equal(parsed.name, "production");
  assert.equal(parsed.values.confirm, "production");
  assert.equal(parsed.values["dry-run"], true);
});

test("parseCli rejects an unknown flag and stray positional arguments", () => {
  assert.throws(() => parseCli(["--env", "staging", "--nope"]), UsageError);
  assert.throws(
    () => parseCli(["--env", "staging", "extra"]),
    (error) => error instanceof UsageError && error.message.includes("extra"),
  );
  const parsed = parseCli(["--env", "staging", "abc", "def"], {}, { maxPositionals: 2 });
  assert.deepEqual(parsed.positionals, ["abc", "def"]);
  assert.throws(() => parseCli(["--env", "staging", "a", "b", "c"], {}, { maxPositionals: 2 }), UsageError);
});

test("loadVars reads only the environment's own file", (t) => {
  const dir = scratchDir(t);
  writeFileSync(path.join(dir, ".dev.vars"), "DATABASE_URL=plain-secret\n");
  const { staging } = loadEnvironments();
  assert.throws(
    () => loadVars(staging, dir),
    (error) =>
      error instanceof UsageError && error.message.includes(".dev.vars.staging") && !error.message.includes("plain-secret"),
  );
});

test("loadVars parses comments, blank lines, CRLF, export, quotes and = inside a value", (t) => {
  const dir = scratchDir(t);
  const text = ["# a comment", "", "export A=1", 'B="two words"', "C='x'", "D=a=b==", ""].join("\r\n");
  writeFileSync(path.join(dir, ".dev.vars.staging"), text);
  assert.deepEqual(loadVars(loadEnvironments().staging, dir), { A: "1", B: "two words", C: "x", D: "a=b==" });
});

test("loadVars names the file but never its content when it cannot be read", (t) => {
  const dir = scratchDir(t);
  mkdirSync(path.join(dir, ".dev.vars.production"));
  assert.throws(
    () => loadVars(loadEnvironments().production, dir),
    (error) => error instanceof UsageError && error.message.includes(".dev.vars.production"),
  );
});

const PRODUCTION_URL = "postgres://prod_role:prod-pass-1@ep-prod-123-pooler.eu-west-2.aws.neon.tech/neondb?sslmode=require";

function writeVars(dir, file, databaseUrl) {
  writeFileSync(path.join(dir, file), `DATABASE_URL=${databaseUrl}\nJWT_SIGNING_SECRET=x\n`);
}

test("databaseIdentity names a database by host and name, not by role, password, pooler or options", () => {
  const pooled = databaseIdentity("postgres://alice:s3cret@ep-x-pooler.eu-west-2.aws.neon.tech/neondb?sslmode=require");
  assert.equal(pooled, databaseIdentity("postgresql://bob:other@ep-x.eu-west-2.aws.neon.tech/neondb"), "same server, same database");
  assert.equal(pooled, databaseIdentity("postgres://alice:s3cret@EP-X.eu-west-2.aws.neon.tech/neondb"), "host case");
  assert.notEqual(pooled, databaseIdentity("postgres://alice:s3cret@ep-x.eu-west-2.aws.neon.tech/other"), "another database");
  assert.notEqual(pooled, databaseIdentity("postgres://alice:s3cret@ep-y.eu-west-2.aws.neon.tech/neondb"), "another server");
  assert.notEqual(pooled, databaseIdentity("postgres://alice:s3cret@ep-x.eu-west-2.aws.neon.tech:6543/neondb"), "another port");
  for (const unusable of ["", "not a url", "https://example.com/neondb", "postgres://alice:s3cret@/neondb"]) {
    assert.equal(databaseIdentity(unusable), null, JSON.stringify(unusable));
  }
});

test("loadVars refuses a database that the other environment's vars file already names, in both directions", (t) => {
  const dir = scratchDir(t);
  const { staging, production } = loadEnvironments();
  writeVars(dir, ".dev.vars.production", PRODUCTION_URL);
  // The same database written another way: the direct host, another role and password, no options.
  writeVars(dir, ".dev.vars.staging", "postgresql://other_role:other-pass-2@ep-prod-123.eu-west-2.aws.neon.tech/neondb");
  for (const config of [staging, production]) {
    assert.throws(
      () => loadVars(config, dir),
      (error) => {
        assert.ok(error instanceof UsageError, `${config.varsFile}: ${error}`);
        assert.ok(error.message.includes(".dev.vars.staging") && error.message.includes(".dev.vars.production"), error.message);
        for (const secret of ["prod-pass-1", "other-pass-2", "prod_role", "other_role", "ep-prod-123", "neondb"]) {
          assert.ok(!error.message.includes(secret), `the message must not echo ${secret}`);
        }
        return true;
      },
      config.varsFile,
    );
  }
});

test("loadVars refuses a staging file that is a copy of production's", (t) => {
  const dir = scratchDir(t);
  writeVars(dir, ".dev.vars.production", PRODUCTION_URL);
  writeVars(dir, ".dev.vars.staging", PRODUCTION_URL);
  assert.throws(() => loadVars(loadEnvironments().staging, dir), UsageError);
});

test("loadVars accepts two databases on one server when their names differ, and two servers", (t) => {
  const dir = scratchDir(t);
  const { staging, production } = loadEnvironments();
  writeVars(dir, ".dev.vars.production", PRODUCTION_URL);
  writeVars(dir, ".dev.vars.staging", "postgres://u:p@ep-prod-123-pooler.eu-west-2.aws.neon.tech/marauders_staging");
  assert.equal(loadVars(staging, dir).DATABASE_URL.includes("marauders_staging"), true);
  writeVars(dir, ".dev.vars.staging", "postgres://u:p@ep-staging-456-pooler.eu-west-2.aws.neon.tech/neondb");
  assert.equal(loadVars(staging, dir).DATABASE_URL.includes("ep-staging-456"), true);
  assert.equal(loadVars(production, dir).DATABASE_URL, PRODUCTION_URL);
});

test("loadVars compares only with what the other file really holds: missing, unreadable, no DATABASE_URL or not a URL is skipped", (t) => {
  const dir = scratchDir(t);
  const { staging } = loadEnvironments();
  writeVars(dir, ".dev.vars.staging", PRODUCTION_URL);
  assert.ok(loadVars(staging, dir).DATABASE_URL, "no production file to compare with");
  mkdirSync(path.join(dir, ".dev.vars.production"));
  assert.ok(loadVars(staging, dir).DATABASE_URL, "a production file that cannot be read");
  rmSync(path.join(dir, ".dev.vars.production"), { recursive: true });
  writeFileSync(path.join(dir, ".dev.vars.production"), "JWT_SIGNING_SECRET=x\n");
  assert.ok(loadVars(staging, dir).DATABASE_URL, "a production file with no DATABASE_URL");
  writeVars(dir, ".dev.vars.production", "not a url");
  assert.ok(loadVars(staging, dir).DATABASE_URL, "a production DATABASE_URL that is not a URL");
  writeFileSync(path.join(dir, ".dev.vars.staging"), "JWT_SIGNING_SECRET=x\n");
  assert.equal(loadVars(staging, dir).DATABASE_URL, undefined, "no DATABASE_URL of its own: the script reports that");
});

test("describeDatabase returns host and database and hides the credentials", () => {
  assert.deepEqual(describeDatabase(SECRET_URL), {
    host: "ep-x-pooler.eu-west-2.aws.neon.tech",
    database: "neondb",
  });
});

test("describeDatabase never echoes its input when it is not a URL", () => {
  let caught;
  try {
    describeDatabase("not a url s3cret");
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof UsageError);
  for (const text of [caught.message, JSON.stringify(caught), util.inspect(caught)]) {
    assert.ok(!text.includes("s3cret"), "the input must not appear anywhere in the error");
  }
});

test("describeDatabase rejects a URL that is not postgres and does not echo it", () => {
  for (const input of ["https://alice:s3cret@example.com/neondb", "postgres://alice:s3cret@/neondb"]) {
    let caught;
    try {
      describeDatabase(input);
    } catch (error) {
      caught = error;
    }
    assert.ok(caught instanceof UsageError, input);
    assert.ok(!util.inspect(caught).includes("s3cret"), input);
  }
});

test("banner names the target and no secret", () => {
  const { production } = loadEnvironments();
  const text = banner({ name: "production", config: production, action: "migrate", databaseUrl: SECRET_URL });
  for (const needle of [
    "production",
    production.worker,
    production.url,
    production.bucket,
    "migrate",
    "ep-x-pooler.eu-west-2.aws.neon.tech",
    "neondb",
  ]) {
    assert.ok(text.includes(needle), `banner lacks ${needle}`);
  }
  assert.ok(!text.includes("s3cret"));
  assert.ok(!text.includes("alice"));
});

test("banner works without a database", () => {
  const { staging } = loadEnvironments();
  const text = banner({ name: "staging", config: staging, action: "deploy" });
  assert.ok(text.includes("staging") && text.includes("deploy") && text.includes(staging.worker));
});

test("confirm with no phrase resolves and never asks", async () => {
  const ask = async () => assert.fail("must not ask");
  await confirm({ phrase: null, isTTY: false, ask });
  await confirm({ phrase: null, isTTY: true, ask });
});

test("confirm accepts exactly the phrase as --confirm and rejects anything else", async () => {
  const ask = async () => assert.fail("must not ask when --confirm was given");
  await confirm({ phrase: "production", flag: "production", isTTY: false, ask });
  await assert.rejects(confirm({ phrase: "production", flag: "yes", isTTY: false, ask }), UsageError);
  await assert.rejects(confirm({ phrase: "production", flag: "yes", isTTY: true, ask }), UsageError);
});

test("confirm without a terminal and without --confirm says how to confirm", async () => {
  await assert.rejects(
    confirm({ phrase: "production", isTTY: false, ask: async () => assert.fail("no terminal, no question") }),
    (error) => error instanceof UsageError && error.message.includes('--confirm "production"'),
  );
});

test("confirm on a terminal asks once and compares the trimmed answer exactly", async () => {
  const prompts = [];
  const answering = (answer) => async (prompt) => {
    prompts.push(prompt);
    return answer;
  };
  await confirm({ phrase: "production", isTTY: true, ask: answering(" production\n") });
  assert.equal(prompts.length, 1);
  assert.ok(prompts[0].includes("production"));
  await assert.rejects(confirm({ phrase: "production", isTTY: true, ask: answering("Production") }), UsageError);
  assert.equal(prompts.length, 2);
});

test("formatCliError prints a UsageError plainly and exits 2", () => {
  assert.deepEqual(formatCliError(new UsageError("--env is required")), { message: "error: --env is required", exitCode: 2 });
});

test("formatCliError prints any other error as name and message only, never its properties", () => {
  const invalid = new TypeError("Invalid URL");
  invalid.code = "ERR_INVALID_URL";
  invalid.input = "postgres://alice:s3cret@host/db";
  const formatted = formatCliError(invalid);
  assert.equal(formatted.exitCode, 1);
  assert.equal(formatted.message, "error: TypeError [ERR_INVALID_URL]: Invalid URL");
  assert.ok(!formatted.message.includes("s3cret"));
  assert.equal(formatCliError("s3cret thrown as a string").message, "error: Error: unexpected failure");
});
