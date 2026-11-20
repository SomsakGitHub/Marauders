#!/usr/bin/env node
/**
 * Deletes every feed_videos row of ONE environment and the objects those rows point at in that environment's bucket.
 *
 *   node scripts/purge-videos.mjs --env <staging|production> [--confirm "<phrase>"]
 *
 * The database comes from the environment's vars file (backend/.dev.vars.<env>) and nowhere else. The script shows
 * where it is going and how much it will delete, then asks for the phrase `purge <env>` (typed, or passed with
 * --confirm when there is no terminal) BEFORE it deletes anything. If any object delete fails the rows are kept, so
 * a re-run can try again (scripts/lib/purge.mjs holds the order).
 *
 * Objects go through `wrangler r2 object delete --remote`. Until 2026-11-19 the script left `--remote` out and wrangler
 * acted on its local simulator, so earlier purges removed database rows only: the first purge after that change
 * deletes real objects. Cost to know: an HLS clip tries up to 201 deletes (the master playlist and seg000 to seg199),
 * one wrangler process each, so a purge of many HLS clips takes a while. Every failed delete counts as a failure,
 * a key that is not there included (scripts/lib/r2.mjs says why): if R2 refuses to delete an absent key, a purge of an
 * HLS clip with fewer than 200 segments stops at its first absent segment and keeps the rows, until that refusal has
 * been seen on staging and can be told apart from a real failure.
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { neon, neonConfig } from "@neondatabase/serverless";
import ws from "ws";

import { purgeVideos } from "./lib/purge.mjs";
import { deleteR2Object } from "./lib/r2.mjs";
import { BACKEND_DIR, UsageError, banner, confirm, loadVars, parseCli, runCli } from "./lib/targets.mjs";

neonConfig.webSocketConstructor = ws;

const execFileAsync = promisify(execFile);
const runNpx = (args) => execFileAsync("npx", args, { cwd: BACKEND_DIR });

async function main() {
  const { name, config, values } = parseCli(process.argv.slice(2));
  const databaseUrl = loadVars(config).DATABASE_URL;
  if (!databaseUrl) {
    throw new UsageError(`DATABASE_URL is missing in ${config.varsFile}`);
  }
  console.log(banner({ name, config, action: "purge", databaseUrl }));

  await purgeVideos({
    sql: neon(databaseUrl),
    config,
    confirm: (phrase) => confirm({ phrase, flag: values.confirm }),
    deleteObject: (bucket, key) => deleteR2Object({ run: runNpx, bucket, key }),
    log: console.log,
  });
}

runCli(main);
