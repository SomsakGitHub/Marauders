// Tests of backend/scripts/lib/migrations.mjs (tracked migrations) and of the db:migrate CLI's refusals.
// A fake `query` records every call, so no test touches a database or the network.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  NEVER_MIGRATED,
  listMigrationFiles,
  planMigrations,
  runMigrations,
  statementsFromSql,
} from "../../scripts/lib/migrations.mjs";
import { BACKEND_DIR, UsageError } from "../../scripts/lib/targets.mjs";

const SQL_DIR = path.join(BACKEND_DIR, "sql");

const REAL_NAMES = [
  "001_schema.sql",
  "002_seed.sql",
  "003_remove_google_seeds.sql",
  "005_feed_video_coordinates.sql",
  "006_app_users_and_ownership.sql",
  "007_app_users_country.sql",
  "008_app_users_country_index.sql",
  "009_app_users_location.sql",
  "010_rate_limit_counters.sql",
  "011_app_users_handle.sql",
  "012_backfill_feed_author_handle.sql",
  "013_drop_music_title.sql",
  "014_app_users_avatar.sql",
  "015_video_audio_assessment.sql",
  "016_dubbed_audio_reports.sql",
  "017_comments.sql",
  "018_video_likes.sql",
  "019_user_follows.sql",
  "020_location_sharing.sql",
  "021_background_location_consent.sql",
  "022_refresh_tokens.sql",
  "023_feed_video_upload_key.sql",
];

// Statements per real file, measured on 2026-11-19 with the inline algorithm of the old migrate.mjs.
const REAL_STATEMENT_COUNTS = [3, 0, 1, 6, 4, 3, 1, 5, 2, 6, 1, 1, 3, 1, 1, 2, 2, 2, 1, 2, 3, 2];

const sha = (text) => createHash("sha256").update(text).digest("hex");

function file(name, text) {
  return { name, sha256: sha(text), text };
}

const FILE_A = file("001_a.sql", "CREATE TABLE a (id int);\nCREATE INDEX a_i ON a (id); -- trailing comment\n");
const FILE_B = file("002_b.sql", "ALTER TABLE a ADD COLUMN b int;\nALTER TABLE a ADD COLUMN fail_me int;\n");
const FILE_C = file("003_c.sql", "CREATE TABLE c (id int);\n");
const FILES = [FILE_A, FILE_B, FILE_C];

/** A database that remembers what a migration run did. `calls` lists every query in the order it was sent. */
function fakeDatabase({ hasTable = true, recorded = [], failOn } = {}) {
  const state = { hasTable, recorded: recorded.map((row) => ({ ...row })) };
  const calls = [];
  async function query(text, values) {
    calls.push({ text, values });
    if (/^\s*CREATE TABLE IF NOT EXISTS schema_migrations/i.test(text)) {
      state.hasTable = true;
      return { rows: [] };
    }
    if (/to_regclass/i.test(text)) {
      return { rows: [{ found: state.hasTable ? "schema_migrations" : null }] };
    }
    if (/^\s*SELECT name, sha256 FROM schema_migrations/i.test(text)) {
      if (!state.hasTable) {
        throw new Error('relation "schema_migrations" does not exist');
      }
      return { rows: state.recorded.map((row) => ({ ...row })) };
    }
    if (/^\s*INSERT INTO schema_migrations/i.test(text)) {
      const [name, sha256] = values;
      const existing = state.recorded.find((row) => row.name === name);
      if (existing) {
        existing.sha256 = sha256;
      } else {
        state.recorded.push({ name, sha256 });
      }
      return { rows: [] };
    }
    if (failOn?.(text)) {
      throw new Error("boom");
    }
    return { rows: [] };
  }
  return { query, calls, state };
}

/** What a run did, in order: `create-table`, `read`, `sql: <statement>` and `record <name>`. */
function describeCalls(calls) {
  return calls.map(({ text, values }) => {
    if (/^\s*CREATE TABLE IF NOT EXISTS schema_migrations/i.test(text)) return "create-table";
    if (/^\s*INSERT INTO schema_migrations/i.test(text)) return `record ${values[0]}`;
    if (/^\s*SELECT/i.test(text)) return "read";
    return `sql: ${text}`;
  });
}

function recordedLike(files) {
  return files.map(({ name, sha256 }) => ({ name, sha256 }));
}

test("lists the 22 real files in numeric order and never 004", async () => {
  const files = await listMigrationFiles(SQL_DIR);
  assert.deepEqual(files.map((entry) => entry.name), REAL_NAMES);
  assert.deepEqual(NEVER_MIGRATED, ["004_purge_feed_videos.sql"]);
});

test("listMigrationFiles skips files that are not migrations and orders by number", async (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), "migrations-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const name of ["010_b.sql", "002_a.sql", "004_purge_feed_videos.sql", "notes.txt", "02_short.sql", "003_c.sql.bak"]) {
    writeFileSync(path.join(dir, name), "SELECT 1;");
  }
  mkdirSync(path.join(dir, "011_folder.sql"));
  const files = await listMigrationFiles(dir);
  assert.deepEqual(files.map((entry) => entry.name), ["002_a.sql", "010_b.sql"]);
});

test("splits statements as the old script did", async () => {
  const files = await listMigrationFiles(SQL_DIR);
  const statementsPerFile = files.map((entry) => statementsFromSql(entry.text));
  assert.deepEqual(statementsPerFile.map((statements) => statements.length), REAL_STATEMENT_COUNTS);
  assert.equal(statementsPerFile.flat().length, 52);
  for (const statement of statementsPerFile.flat()) {
    assert.ok(!statement.includes("--"), "comments are stripped");
    assert.equal(statement, statement.trim());
    assert.ok(statement.length > 0);
  }
});

test("statementsFromSql drops comments, blank pieces and surrounding whitespace", () => {
  assert.deepEqual(statementsFromSql("-- only a comment\n"), []);
  assert.deepEqual(statementsFromSql("SELECT 1; -- one\n\n  SELECT 2 ;;\n"), ["SELECT 1", "SELECT 2"]);
});

test("sha256 is the hex digest of the file text", async () => {
  const files = await listMigrationFiles(SQL_DIR);
  for (const entry of files) {
    assert.match(entry.sha256, /^[0-9a-f]{64}$/);
    assert.equal(entry.sha256, sha(entry.text));
  }
  const again = await listMigrationFiles(SQL_DIR);
  assert.deepEqual(again.map((entry) => entry.sha256), files.map((entry) => entry.sha256));
});

test("plans pending, changed, unknown and out-of-order files", () => {
  const local = [
    { name: "001_a.sql", sha256: "h1" },
    { name: "002_b.sql", sha256: "h2" },
    { name: "003_c.sql", sha256: "h3" },
  ];
  assert.deepEqual(
    planMigrations(local, [
      { name: "001_a.sql", sha256: "h1" },
      { name: "003_c.sql", sha256: "h3" },
    ]),
    { pending: ["002_b.sql"], changed: [], unknown: [], outOfOrder: ["002_b.sql"] },
  );
  assert.deepEqual(
    planMigrations(local, [
      { name: "001_a.sql", sha256: "edited" },
      { name: "002_b.sql", sha256: "h2" },
      { name: "003_c.sql", sha256: "h3" },
      { name: "009_gone.sql", sha256: "h9" },
    ]),
    { pending: [], changed: ["001_a.sql"], unknown: ["009_gone.sql"], outOfOrder: [] },
  );
  assert.deepEqual(planMigrations(local, []), {
    pending: ["001_a.sql", "002_b.sql", "003_c.sql"],
    changed: [],
    unknown: [],
    outOfOrder: [],
  });
  assert.deepEqual(planMigrations([], []), { pending: [], changed: [], unknown: [], outOfOrder: [] });
});

test("a fresh database creates the table, applies every file in order and records each one after its statements", async () => {
  const database = fakeDatabase({ hasTable: false });
  const ok = [FILE_A, FILE_C];
  const result = await runMigrations({ query: database.query, files: ok, dryRun: false, acceptChanged: [], log: () => {} });
  const steps = describeCalls(database.calls);
  assert.equal(steps[0], "create-table");
  assert.deepEqual(steps.filter((step) => step !== "read"), [
    "create-table",
    "sql: CREATE TABLE a (id int)",
    "sql: CREATE INDEX a_i ON a (id)",
    "record 001_a.sql",
    "sql: CREATE TABLE c (id int)",
    "record 003_c.sql",
  ]);
  assert.deepEqual(result, { applied: ["001_a.sql", "003_c.sql"], pending: [] });
  assert.deepEqual(database.state.recorded, [
    { name: "001_a.sql", sha256: FILE_A.sha256 },
    { name: "003_c.sql", sha256: FILE_C.sha256 },
  ]);
  const create = database.calls[0].text;
  assert.match(create, /name text PRIMARY KEY/i);
  assert.match(create, /sha256 text NOT NULL/i);
  assert.match(create, /applied_at timestamptz NOT NULL DEFAULT now\(\)/i);
  const insert = database.calls.find((call) => /^\s*INSERT INTO schema_migrations/i.test(call.text)).text;
  assert.match(insert, /ON CONFLICT \(name\) DO UPDATE SET sha256 = EXCLUDED\.sha256, applied_at = now\(\)/i);
});

test("a failure inside a file leaves that file unrecorded and stops", async () => {
  const database = fakeDatabase({ hasTable: false, failOn: (text) => text.includes("fail_me") });
  await assert.rejects(
    runMigrations({ query: database.query, files: FILES, dryRun: false, acceptChanged: [], log: () => {} }),
    (error) => error.message.includes("002_b.sql") && error.message.includes("statement 2"),
  );
  assert.deepEqual(database.state.recorded.map((row) => row.name), ["001_a.sql"]);
  const steps = describeCalls(database.calls);
  assert.ok(!steps.some((step) => step.includes("CREATE TABLE c")), "the next file never ran");
  assert.ok(!steps.includes("record 002_b.sql"));
});

test("a second run applies nothing", async () => {
  const database = fakeDatabase({ recorded: recordedLike(FILES) });
  const result = await runMigrations({ query: database.query, files: FILES, dryRun: false, acceptChanged: [], log: () => {} });
  assert.deepEqual(result, { applied: [], pending: [] });
  assert.deepEqual(describeCalls(database.calls).filter((step) => step !== "read"), ["create-table"]);
});

test("a changed file stops the run unless accepted", async () => {
  const edited = { ...FILE_A, sha256: "sha-of-the-version-that-was-applied" };
  const recorded = recordedLike([edited, FILE_B, FILE_C]);

  const stopped = fakeDatabase({ recorded });
  await assert.rejects(
    runMigrations({ query: stopped.query, files: FILES, dryRun: false, acceptChanged: [], log: () => {} }),
    (error) => error instanceof UsageError && error.message.includes("001_a.sql") && error.message.includes("--accept-changed 001_a.sql"),
  );
  assert.deepEqual(describeCalls(stopped.calls).filter((step) => step.startsWith("sql:") || step.startsWith("record")), []);

  const dry = fakeDatabase({ recorded });
  await assert.rejects(
    runMigrations({ query: dry.query, files: FILES, dryRun: true, acceptChanged: [], log: () => {} }),
    (error) => error instanceof UsageError && error.message.includes("--accept-changed 001_a.sql"),
  );

  const accepted = fakeDatabase({ recorded });
  const result = await runMigrations({
    query: accepted.query,
    files: FILES,
    dryRun: false,
    acceptChanged: ["001_a.sql"],
    log: () => {},
  });
  assert.deepEqual(result, { applied: ["001_a.sql"], pending: [] });
  assert.deepEqual(describeCalls(accepted.calls).filter((step) => step !== "read" && step !== "create-table"), [
    "sql: CREATE TABLE a (id int)",
    "sql: CREATE INDEX a_i ON a (id)",
    "record 001_a.sql",
  ]);
  assert.equal(accepted.state.recorded.find((row) => row.name === "001_a.sql").sha256, FILE_A.sha256);
});

test("a dry run writes nothing", async () => {
  const noTable = fakeDatabase({ hasTable: false });
  const lines = [];
  const result = await runMigrations({ query: noTable.query, files: FILES, dryRun: true, acceptChanged: [], log: (line) => lines.push(line) });
  assert.deepEqual(result, { applied: [], pending: ["001_a.sql", "002_b.sql", "003_c.sql"] });
  assert.ok(noTable.calls.length > 0);
  for (const call of noTable.calls) {
    assert.match(call.text, /^\s*SELECT/i, "a dry run only reads");
  }
  assert.equal(noTable.state.hasTable, false, "the tracking table was not created");
  assert.ok(lines.some((line) => line.includes("001_a.sql")), "the plan is printed");

  const upToDate = fakeDatabase({ recorded: recordedLike(FILES) });
  assert.deepEqual(
    await runMigrations({ query: upToDate.query, files: FILES, dryRun: true, acceptChanged: [], log: () => {} }),
    { applied: [], pending: [] },
  );
  for (const call of upToDate.calls) {
    assert.match(call.text, /^\s*SELECT/i);
  }
});

test("the first run says that nothing is recorded and that the files are re-runnable", async () => {
  const lines = [];
  const database = fakeDatabase({ hasTable: false });
  await runMigrations({ query: database.query, files: [FILE_A], dryRun: true, acceptChanged: [], log: (line) => lines.push(line) });
  const text = lines.join("\n");
  assert.match(text, /re-runnable/);
  assert.match(text, /nothing is recorded/i);
});

test("recorded names with no local file are logged, not fatal", async () => {
  const lines = [];
  const database = fakeDatabase({ recorded: [...recordedLike(FILES), { name: "099_gone.sql", sha256: "x" }] });
  const result = await runMigrations({
    query: database.query,
    files: FILES,
    dryRun: false,
    acceptChanged: [],
    log: (line) => lines.push(line),
  });
  assert.deepEqual(result, { applied: [], pending: [] });
  assert.ok(lines.some((line) => line.includes("099_gone.sql")));
});

test("a file numbered below an applied one is applied and called out of order", async () => {
  const lines = [];
  const database = fakeDatabase({ recorded: recordedLike([FILE_A, FILE_C]) });
  const result = await runMigrations({
    query: database.query,
    files: [FILE_A, { ...FILE_B, text: "ALTER TABLE a ADD COLUMN b int;\n", sha256: sha("ALTER TABLE a ADD COLUMN b int;\n") }, FILE_C],
    dryRun: false,
    acceptChanged: [],
    log: (line) => lines.push(line),
  });
  assert.deepEqual(result.applied, ["002_b.sql"]);
  assert.ok(lines.some((line) => line.includes("002_b.sql") && /out of order/i.test(line)));
});

test("the db:migrate CLI refuses a missing or unknown target before it reads any vars file", () => {
  const script = path.join(BACKEND_DIR, "scripts", "migrate.mjs");
  const cases = [
    { args: [], expect: "--env" },
    { args: ["--env", "qa"], expect: "qa" },
    { args: ["--env", "staging", "--nope"], expect: "nope" },
    { args: ["--env", "staging", "extra"], expect: "extra" },
  ];
  for (const { args, expect } of cases) {
    const run = spawnSync(process.execPath, [script, ...args], { encoding: "utf8", timeout: 20000 });
    assert.equal(run.status, 2, `${args.join(" ")} -> ${run.stderr}`);
    assert.ok(run.stderr.startsWith("error: "), run.stderr);
    assert.ok(run.stderr.includes(expect), run.stderr);
    assert.ok(!run.stderr.includes("    at "), "no stack trace");
  }
});
