#!/usr/bin/env node
/**
 * Build HLS (single 720p ladder) from a local MP4 and upload to R2.
 * Updates Neon stream_url to the master playlist on the Worker.
 *
 * Prerequisites: ffmpeg, wrangler logged in, DATABASE_URL in env.
 *
 * Usage:
 *   node scripts/hls-transcode-r2.mjs <video-uuid> /path/to/source.mp4 [worker-origin]
 *
 * Example:
 *   DATABASE_URL="postgresql://..." \
 *   node scripts/hls-transcode-r2.mjs 550e8400-e29b-41d4-a716-446655440000 ./clip.mp4 \
 *     https://marauders-api.js6ctz7gtj.workers.dev
 */

import { execFile } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { neon } from "@neondatabase/serverless";

const execFileAsync = promisify(execFile);
const backendDir = join(dirname(fileURLToPath(import.meta.url)), "..");

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

async function main() {
  const videoId = process.argv[2];
  const sourcePath = process.argv[3];
  const workerOrigin = (process.argv[4] ?? process.env.MARAUDERS_API_ORIGIN ?? "")
    .replace(/\/$/u, "");

  if (!videoId || !UUID_RE.test(videoId)) {
    console.error("video-uuid must be a valid UUID");
    process.exit(1);
  }
  if (!sourcePath) {
    console.error("source mp4 path is required");
    process.exit(1);
  }
  if (!workerOrigin.startsWith("https://")) {
    console.error("worker origin must be https (arg 3 or MARAUDERS_API_ORIGIN)");
    process.exit(1);
  }
  if (!process.env.DATABASE_URL) {
    console.error("DATABASE_URL is required");
    process.exit(1);
  }

  const workDir = await mkdtemp(join(tmpdir(), "marauders-hls-"));
  const masterName = "master.m3u8";
  const masterPath = join(workDir, masterName);
  const segmentPattern = join(workDir, "seg%03d.ts");

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
      "-movflags",
      "+faststart",
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

  const prefix = `videos/${videoId}`;
  const files = await readdir(workDir);
  const uploadables = files.filter(
    (name) => name === masterName || /^seg\d{3}\.ts$/u.test(name),
  );

  console.log(`uploading ${uploadables.length} objects to R2…`);
  for (const name of uploadables) {
    const key = `${prefix}/${name}`;
    const filePath = join(workDir, name);
    await execFileAsync(
      "npx",
      ["wrangler", "r2", "object", "put", `marauders-videos/${key}`, "--file", filePath],
      { cwd: backendDir },
    );
  }

  const streamUrl = `${workerOrigin}/v1/media/${prefix}/${masterName}`;
  const sql = neon(process.env.DATABASE_URL);
  const rows = await sql`
    UPDATE feed_videos
    SET stream_url = ${streamUrl}
    WHERE id = ${videoId}::uuid
    RETURNING id
  `;

  if (rows.length < 1) {
    console.warn(
      `warning: no feed_videos row updated for id=${videoId}; files are on R2 at ${prefix}/`,
    );
  } else {
    console.log(`stream_url -> ${streamUrl}`);
  }

  await rm(workDir, { recursive: true, force: true });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
