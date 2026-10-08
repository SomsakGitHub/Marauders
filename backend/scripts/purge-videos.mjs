#!/usr/bin/env node
/**
 * Delete all feed_videos rows and matching objects in R2 (marauders-videos).
 *
 * DATABASE_URL from env or backend/.dev.vars
 */

import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { neon } from "@neondatabase/serverless";
import ws from "ws";
import { neonConfig } from "@neondatabase/serverless";

neonConfig.webSocketConstructor = ws;

const execFileAsync = promisify(execFile);
const backendDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const BUCKET = "marauders-videos";

function loadDatabaseUrl() {
  if (process.env.DATABASE_URL) {
    return process.env.DATABASE_URL;
  }
  try {
    const line = readFileSync(join(backendDir, ".dev.vars"), "utf8")
      .split("\n")
      .find((entry) => entry.startsWith("DATABASE_URL="));
    if (line) {
      return line.slice("DATABASE_URL=".length).trim();
    }
  } catch {
    // ignore
  }
  throw new Error("DATABASE_URL missing (env or backend/.dev.vars)");
}

function mediaKeyFromStreamUrl(streamUrl) {
  try {
    const pathname = new URL(streamUrl).pathname;
    const prefix = "/v1/media/";
    if (!pathname.startsWith(prefix)) {
      return null;
    }
    return decodeURIComponent(pathname.slice(prefix.length));
  } catch {
    return null;
  }
}

function keysToDeleteForRow(streamUrl) {
  const key = mediaKeyFromStreamUrl(streamUrl);
  if (!key) {
    return [];
  }

  const keys = [key];
  const hlsMatch = /^videos\/[0-9a-f-]{36}\/master\.m3u8$/iu.exec(key);
  if (hlsMatch) {
    const prefix = key.replace(/master\.m3u8$/u, "");
    for (let i = 0; i < 200; i += 1) {
      keys.push(`${prefix}seg${String(i).padStart(3, "0")}.ts`);
    }
  }
  return keys;
}

async function deleteR2Object(key) {
  const objectPath = `${BUCKET}/${key}`;
  try {
    await execFileAsync(
      "npx",
      ["wrangler", "r2", "object", "delete", objectPath],
      { cwd: backendDir },
    );
    return "deleted";
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("404") || message.includes("not found")) {
      return "missing";
    }
    return `error: ${message.slice(0, 120)}`;
  }
}

async function main() {
  const databaseUrl = loadDatabaseUrl();
  const sql = neon(databaseUrl);

  const rows = await sql`SELECT id, stream_url FROM feed_videos ORDER BY created_at ASC`;
  console.log(`feed_videos rows: ${rows.length}`);

  const keySet = new Set();
  for (const row of rows) {
    for (const key of keysToDeleteForRow(row.stream_url)) {
      keySet.add(key);
    }
  }

  console.log(`r2 objects to try: ${keySet.size}`);
  let deleted = 0;
  let missing = 0;
  for (const key of keySet) {
    const result = await deleteR2Object(key);
    if (result === "deleted") {
      deleted += 1;
      console.log(`  deleted ${key}`);
    } else if (result === "missing") {
      missing += 1;
    } else {
      console.warn(`  ${key}: ${result}`);
    }
  }

  const removed = await sql`DELETE FROM feed_videos RETURNING id`;
  console.log(`database rows removed: ${removed.length}`);
  console.log(`r2 deleted=${deleted} missing=${missing}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
