#!/usr/bin/env node
/**
 * Builds HLS (720p, ~2s segments) from a clip, uploads it to ONE environment's R2 bucket and points that
 * environment's feed_videos row at master.m3u8.
 *
 * Prerequisites: ffmpeg, wrangler logged in, DATABASE_URL in the environment's vars file (backend/.dev.vars.<env>).
 * The bucket and the new stream_url come from backend/environments.json; uploads go through
 * `wrangler r2 object put --remote` (scripts/lib/r2.mjs). Production asks for the phrase `production` first.
 *
 * Usage:
 *   node scripts/hls-transcode-r2.mjs --env <staging|production> <feed_videos.id> [local-source.mp4] [--confirm "<phrase>"]
 *
 * If local-source is omitted, downloads the row's current stream_url (an MP4 served by that environment's Worker).
 *
 * Example:
 *   cd backend && npm run video:hls -- --env staging 9e95610c-5540-4b88-ae42-bc3f14b56d5c
 */

import { execFile } from "node:child_process";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import { neon } from "@neondatabase/serverless";

import { masterStreamUrl, r2ObjectArgs } from "./lib/r2.mjs";
import { BACKEND_DIR, UsageError, banner, confirm, loadVars, parseCli, runCli } from "./lib/targets.mjs";

const execFileAsync = promisify(execFile);

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const MEDIA_OBJECT_RE = /\/v1\/media\/(videos\/[0-9a-f-]{36}\.mp4)$/iu;

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
  const { name, config, values, positionals } = parseCli(process.argv.slice(2), {}, { maxPositionals: 2 });
  const [feedRowId, localSource] = positionals;
  if (!feedRowId || !UUID_RE.test(feedRowId)) {
    throw new UsageError(
      "usage: node scripts/hls-transcode-r2.mjs --env <staging|production> <feed_videos.id> [local-source.mp4]; feed_videos.id must be a UUID",
    );
  }
  let sourcePath = localSource;

  const databaseUrl = loadVars(config).DATABASE_URL;
  if (!databaseUrl) {
    throw new UsageError(`DATABASE_URL is missing in ${config.varsFile}`);
  }
  console.log(banner({ name, config, action: "video:hls", databaseUrl }));

  const sql = neon(databaseUrl);
  const rows = await sql`
    SELECT id, stream_url
    FROM feed_videos
    WHERE id = ${feedRowId}::uuid
  `;
  if (rows.length < 1) {
    throw new UsageError(`no feed_videos row for id=${feedRowId} in ${name}`);
  }

  const streamUrl = rows[0].stream_url;
  const objectUuid = objectUuidFromStreamUrl(streamUrl);
  const r2Prefix = `videos/${objectUuid}`;

  await confirm({ phrase: config.confirm.write, flag: values.confirm });

  const workDir = await mkdtemp(join(tmpdir(), "marauders-hls-"));
  try {
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
      (fileName) => fileName === masterName || /^seg\d{3}\.ts$/u.test(fileName),
    );

    console.log(`uploading ${uploadables.length} objects to ${config.bucket} at ${r2Prefix}/…`);
    for (const fileName of uploadables) {
      const key = `${r2Prefix}/${fileName}`;
      const filePath = join(workDir, fileName);
      await execFileAsync("npx", r2ObjectArgs("put", config.bucket, key, ["--file", filePath]), { cwd: BACKEND_DIR });
    }

    const newStreamUrl = masterStreamUrl(config, r2Prefix);
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
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}

runCli(main);
