#!/usr/bin/env node
/**
 * Build HLS (720p, ~2s segments) and upload to R2; point feed_videos at master.m3u8.
 *
 * Prerequisites: ffmpeg, wrangler logged in, DATABASE_URL in env or backend/.dev.vars
 *
 * Usage:
 *   node scripts/hls-transcode-r2.mjs <feed_videos.id> [local-source.mp4] [worker-origin]
 *
 * If local-source is omitted, downloads the row's current streamURL (MP4 on Worker).
 *
 * Example:
 *   cd backend && npm run video:hls -- 9e95610c-5540-4b88-ae42-bc3f14b56d5c
 */

import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { neon } from "@neondatabase/serverless";

const execFileAsync = promisify(execFile);
const backendDir = join(dirname(fileURLToPath(import.meta.url)), "..");

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const MEDIA_OBJECT_RE = /\/v1\/media\/(videos\/[0-9a-f-]{36}\.mp4)$/iu;

function loadDatabaseUrl() {
  if (process.env.DATABASE_URL) {
    return process.env.DATABASE_URL;
  }
  const line = readFileSync(join(backendDir, ".dev.vars"), "utf8")
    .split("\n")
    .find((entry) => entry.startsWith("DATABASE_URL="));
  if (!line) {
    throw new Error("DATABASE_URL missing (env or backend/.dev.vars)");
  }
  return line.slice("DATABASE_URL=".length).trim();
}

function objectUuidFromStreamUrl(streamUrl) {
  const match = MEDIA_OBJECT_RE.exec(streamUrl);
  if (!match) {
    throw new Error(`stream_url is not an MP4 on this API: ${streamUrl}`);
  }
  const objectKey = match[1];
  const fileName = objectKey.split("/").pop() ?? "";
  const uuid = fileName.replace(/\.mp4$/iu, "");
  if (!UUID_RE.test(uuid)) {
    throw new Error(`could not parse object uuid from ${objectKey}`);
  }
  return uuid;
}

async function downloadToFile(url, destination) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`download failed status=${response.status}`);
  }
  const bytes = await response.arrayBuffer();
  await writeFile(destination, Buffer.from(bytes));
}

async function main() {
  const feedRowId = process.argv[2];
  let sourcePath = process.argv[3];
  const workerOrigin = (process.argv[4] ?? process.env.MARAUDERS_API_ORIGIN ?? "")
    .replace(/\/$/u, "");

  if (!feedRowId || !UUID_RE.test(feedRowId)) {
    console.error("usage: node scripts/hls-transcode-r2.mjs <feed_videos.id> [local.mp4] [worker-origin]");
    process.exit(1);
  }
  if (!workerOrigin.startsWith("https://")) {
    console.error("worker origin must be https (arg 3 or MARAUDERS_API_ORIGIN)");
    process.exit(1);
  }

  const databaseUrl = loadDatabaseUrl();
  const sql = neon(databaseUrl);
  const rows = await sql`
    SELECT id, stream_url
    FROM feed_videos
    WHERE id = ${feedRowId}::uuid
  `;
  if (rows.length < 1) {
    console.error(`no feed_videos row for id=${feedRowId}`);
    process.exit(1);
  }

  const streamUrl = rows[0].stream_url;
  const objectUuid = objectUuidFromStreamUrl(streamUrl);
  const r2Prefix = `videos/${objectUuid}`;

  const workDir = await mkdtemp(join(tmpdir(), "marauders-hls-"));
  const masterName = "master.m3u8";
  const masterPath = join(workDir, masterName);
  const segmentPattern = join(workDir, "seg%03d.ts");

  if (!sourcePath) {
    sourcePath = join(workDir, "source.mp4");
    console.log(`downloading ${streamUrl}…`);
    await downloadToFile(streamUrl, sourcePath);
  }

  console.log("transcoding with ffmpeg…");
  await execFileAsync(
    "ffmpeg",
    [
      "-y",
      "-i",
      sourcePath,
      "-vf",
      "scale=-2:720",
      "-c:v",
      "h264",
      "-profile:v",
      "main",
      "-preset",
      "fast",
      "-crf",
      "23",
      "-c:a",
      "aac",
      "-b:a",
      "128k",
      "-hls_time",
      "2",
      "-hls_playlist_type",
      "vod",
      "-hls_segment_filename",
      segmentPattern,
      masterPath,
    ],
    { maxBuffer: 20 * 1024 * 1024 },
  );

  const files = await readdir(workDir);
  const uploadables = files.filter(
    (name) => name === masterName || /^seg\d{3}\.ts$/u.test(name),
  );

  console.log(`uploading ${uploadables.length} objects to R2 at ${r2Prefix}/…`);
  for (const name of uploadables) {
    const key = `${r2Prefix}/${name}`;
    const filePath = join(workDir, name);
    await execFileAsync(
      "npx",
      ["wrangler", "r2", "object", "put", `marauders-videos/${key}`, "--file", filePath],
      { cwd: backendDir },
    );
  }

  const newStreamUrl = `${workerOrigin}/v1/media/${r2Prefix}/${masterName}`;
  const updated = await sql`
    UPDATE feed_videos
    SET stream_url = ${newStreamUrl}
    WHERE id = ${feedRowId}::uuid
    RETURNING id
  `;

  if (updated.length < 1) {
    console.warn(`warning: database row not updated; HLS is at ${r2Prefix}/`);
  } else {
    console.log(`stream_url -> ${newStreamUrl}`);
  }

  await rm(workDir, { recursive: true, force: true });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
