// Tracked migrations. Until 2026-11-19 `db:migrate` ran every file of backend/sql again on every run and the list
// of files was hard-coded in the script. Now each environment's database has a `schema_migrations` table that
// records which file was applied and the SHA-256 of its text, so a run applies only what is new, stops when an
// applied file was edited afterwards, and a dry run can say what a real run would do.
//
// The files themselves must stay re-runnable (IF NOT EXISTS, idempotent updates): the first run on a database that
// already holds them (production) applies all of them again, exactly as every run did before, and records them.

import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";

import { UsageError } from "./targets.mjs";

/** Numbered but deliberately not part of the schema: a one-off clean-up that must never run from a script. */
export const NEVER_MIGRATED = ["004_purge_feed_videos.sql"];

const FILE_PATTERN = /^\d{3}_.+\.sql$/;

const CREATE_TABLE =
  "CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())";
const READ_RECORDED = "SELECT name, sha256 FROM schema_migrations";
const TABLE_EXISTS = "SELECT to_regclass('public.schema_migrations')::text AS found";
const RECORD =
  "INSERT INTO schema_migrations (name, sha256) VALUES ($1, $2) ON CONFLICT (name) DO UPDATE SET sha256 = EXCLUDED.sha256, applied_at = now()";

function numberOf(name) {
  return Number.parseInt(name.slice(0, 3), 10);
}

function compareNames(a, b) {
  return numberOf(a) - numberOf(b) || (a < b ? -1 : a > b ? 1 : 0);
}

/** The migration files of `sqlDir` in numeric order, each with its text and the SHA-256 (hex) of that text. */
export async function listMigrationFiles(sqlDir) {
  const entries = await readdir(sqlDir, { withFileTypes: true });
  const names = entries
    .filter((entry) => entry.isFile() && FILE_PATTERN.test(entry.name) && !NEVER_MIGRATED.includes(entry.name))
    .map((entry) => entry.name)
    .sort(compareNames);
  return Promise.all(
    names.map(async (name) => {
      const text = await readFile(path.join(sqlDir, name), "utf8");
      return { name, sha256: createHash("sha256").update(text).digest("hex"), text };
    }),
  );
}

/** The statements of one file, as the old `db:migrate` split them: on `;`, `--` comments removed, empties dropped. */
export function statementsFromSql(sqlText) {
  return sqlText
    .split(";")
    .map((part) => part.replace(/--.*$/gm, "").trim())
    .filter((part) => part.length > 0);
}

/**
 * Compares the files on disk with the recorded ones. `outOfOrder` lists pending files numbered below the highest
 * recorded number (two branches that both added a migration): they still run, but the run says so.
 */
export function planMigrations(local, recorded) {
  const recordedHash = new Map(recorded.map((row) => [row.name, row.sha256]));
  const localNames = new Set(local.map((entry) => entry.name));
  const pending = local.filter((entry) => !recordedHash.has(entry.name)).map((entry) => entry.name);
  const changed = local
    .filter((entry) => recordedHash.has(entry.name) && recordedHash.get(entry.name) !== entry.sha256)
    .map((entry) => entry.name);
  const unknown = recorded.filter((row) => !localNames.has(row.name)).map((row) => row.name);
  const recordedNumbers = recorded.map((row) => numberOf(row.name)).filter(Number.isFinite);
  const highest = recordedNumbers.length > 0 ? Math.max(...recordedNumbers) : -Infinity;
  const outOfOrder = pending.filter((name) => numberOf(name) < highest);
  return { pending, changed, unknown, outOfOrder };
}

/**
 * Applies what is pending. A dry run only reads: it never creates the tracking table and treats a missing table as
 * nothing recorded. A file is recorded only after all its statements ran, so a failure leaves it pending. An edited
 * file stops the run (also a dry run, so it shows what a real run would do) unless it is named in `acceptChanged`;
 * an accepted one is applied again and its new hash recorded.
 * Returns the names `applied` by a real run, or the names that would be applied (`pending`) by a dry run.
 */
export async function runMigrations({ query, files, dryRun, acceptChanged, log }) {
  let recorded;
  if (dryRun) {
    const probe = await query(TABLE_EXISTS);
    recorded = probe.rows[0]?.found ? (await query(READ_RECORDED)).rows : [];
  } else {
    await query(CREATE_TABLE);
    recorded = (await query(READ_RECORDED)).rows;
  }

  const plan = planMigrations(files, recorded);
  const accepted = new Set(acceptChanged);
  const toApply = files
    .filter((entry) => plan.pending.includes(entry.name) || (plan.changed.includes(entry.name) && accepted.has(entry.name)))
    .map((entry) => entry.name);

  log(`${files.length} migration files, ${recorded.length} recorded as applied`);
  if (recorded.length === 0 && files.length > 0) {
    log(
      "nothing is recorded yet, so every file is pending. The files are re-runnable: applying them to a database that already holds them changes nothing, and they are recorded afterwards.",
    );
  }
  for (const name of plan.unknown) {
    log(`note: ${name} is recorded as applied but has no file here`);
  }
  for (const name of plan.outOfOrder) {
    log(`warning: ${name} is numbered below a migration that is already applied (out of order); it will still run`);
  }
  for (const name of plan.changed) {
    log(`changed: ${name} was edited after it was applied`);
  }
  for (const name of toApply) {
    log(`pending: ${name}`);
  }
  if (toApply.length === 0) {
    log("nothing to apply");
  }

  const blocked = plan.changed.filter((name) => !accepted.has(name));
  if (blocked.length > 0) {
    throw new UsageError(
      `${blocked.join(", ")} was edited after it was applied. If the edit is deliberate and the file can run twice, run again with ${blocked
        .map((name) => `--accept-changed ${name}`)
        .join(" ")}`,
    );
  }
  if (dryRun) {
    return { applied: [], pending: toApply };
  }

  for (const entry of files) {
    if (!toApply.includes(entry.name)) {
      continue;
    }
    const statements = statementsFromSql(entry.text);
    for (const [index, statement] of statements.entries()) {
      try {
        await query(statement);
      } catch (error) {
        throw new Error(
          `${entry.name}: statement ${index + 1} of ${statements.length} failed (${error?.message ?? "unknown error"}). Nothing after it ran and ${entry.name} is not recorded.`,
          { cause: error },
        );
      }
      log(`ok: ${statement.slice(0, 60).replace(/\s+/g, " ")}...`);
    }
    await query(RECORD, [entry.name, entry.sha256]);
    log(`recorded ${entry.name}`);
  }
  return { applied: toApply, pending: [] };
}
