// Tests of backend/scripts/lib/r2.mjs: the only place that builds a `wrangler r2 object` command, and what the R2
// scripts (db:purge, video:hls, test-upload) refuse before they touch a database, a bucket or the network.
//
// Why `--remote` matters: without it wrangler 4.150.0 acts on its local simulator. `db:purge` used to delete database
// rows only, leaving every real object in the bucket, and `video:hls` wrote its files to the simulator and then
// pointed `stream_url` at objects that did not exist.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";

import {
  deleteR2Object,
  keysToDeleteForRow,
  masterStreamUrl,
  mediaKeyFromStreamUrl,
  r2ObjectArgs,
} from "../../scripts/lib/r2.mjs";
import { BACKEND_DIR, loadEnvironments } from "../../scripts/lib/targets.mjs";

const ENVIRONMENTS = loadEnvironments();
const UUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

test("every r2 command ends with --remote", () => {
  assert.deepEqual(r2ObjectArgs("delete", "marauders-videos-staging", "videos/x/seg000.ts"), [
    "wrangler",
    "r2",
    "object",
    "delete",
    "marauders-videos-staging/videos/x/seg000.ts",
    "--remote",
  ]);
  assert.deepEqual(r2ObjectArgs("put", "marauders-videos", "videos/x/master.m3u8", ["--file", "/tmp/a"]), [
    "wrangler",
    "r2",
    "object",
    "put",
    "marauders-videos/videos/x/master.m3u8",
    "--file",
    "/tmp/a",
    "--remote",
  ]);
  for (const action of ["put", "delete"]) {
    for (const extra of [undefined, [], ["--file", "/tmp/a"], ["--content-type", "video/mp2t"]]) {
      assert.equal(r2ObjectArgs(action, "b", "k", extra).at(-1), "--remote", `${action} ${JSON.stringify(extra)}`);
    }
  }
});

test("r2ObjectArgs builds only put and delete", () => {
  assert.throws(() => r2ObjectArgs("get", "b", "k"), /put|delete/);
});

test("keysToDeleteForRow: an MP4 clip is one object", () => {
  assert.deepEqual(keysToDeleteForRow(`https://marauders-api.js6ctz7gtj.workers.dev/v1/media/videos/${UUID}.mp4`), [
    `videos/${UUID}.mp4`,
  ]);
});

test("keysToDeleteForRow: an HLS clip is its master playlist and up to 200 segments", () => {
  const keys = keysToDeleteForRow(`https://marauders-api.js6ctz7gtj.workers.dev/v1/media/videos/${UUID}/master.m3u8`);
  assert.equal(keys.length, 201);
  assert.equal(keys[0], `videos/${UUID}/master.m3u8`);
  assert.equal(keys[1], `videos/${UUID}/seg000.ts`);
  assert.equal(keys.at(-1), `videos/${UUID}/seg199.ts`);
  assert.equal(new Set(keys).size, 201);
});

test("keysToDeleteForRow: a URL outside /v1/media/ owns no object", () => {
  assert.deepEqual(keysToDeleteForRow("https://example.com/other/video.mp4"), []);
  assert.deepEqual(keysToDeleteForRow("not a url"), []);
});

test("mediaKeyFromStreamUrl decodes the key and refuses what is not a media URL", () => {
  assert.equal(mediaKeyFromStreamUrl("https://h.example/v1/media/videos/a%20b.mp4"), "videos/a b.mp4");
  assert.equal(mediaKeyFromStreamUrl("https://h.example/v2/media/x"), null);
  assert.equal(mediaKeyFromStreamUrl("::::"), null);
});

test("masterStreamUrl uses the environment's own URL", () => {
  assert.equal(
    masterStreamUrl(ENVIRONMENTS.staging, `videos/${UUID}`),
    `https://marauders-api-staging.js6ctz7gtj.workers.dev/v1/media/videos/${UUID}/master.m3u8`,
  );
  assert.equal(
    masterStreamUrl(ENVIRONMENTS.production, `videos/${UUID}`),
    `https://marauders-api.js6ctz7gtj.workers.dev/v1/media/videos/${UUID}/master.m3u8`,
  );
});

/** What a rejected `execFile` carries: a message that starts with the command line (and so holds the key), then stderr. */
function failedRun({ key, stderr }) {
  return Object.assign(
    new Error(`Command failed: npx wrangler r2 object delete marauders-videos-staging/${key} --remote\n${stderr}`),
    { stderr, code: 1 },
  );
}

test("deleteR2Object runs the --remote delete of that bucket and key and says deleted", async () => {
  const runs = [];
  const result = await deleteR2Object({
    run: async (args) => {
      runs.push(args);
    },
    bucket: "marauders-videos-staging",
    key: `videos/${UUID}.mp4`,
  });
  assert.equal(result, "deleted");
  assert.deepEqual(runs, [r2ObjectArgs("delete", "marauders-videos-staging", `videos/${UUID}.mp4`)]);
});

test("deleteR2Object does not read a failure as missing because the command line holds 404", async () => {
  // Keys are UUIDs, so about one in a hundred holds the digits 404, and the command line is part of the error message.
  const key = "videos/a4040000-0000-4000-8000-000000000000.mp4";
  const result = await deleteR2Object({
    run: async () => {
      throw failedRun({ key, stderr: "fetch failed" });
    },
    bucket: "marauders-videos-staging",
    key,
  });
  assert.ok(result.startsWith("error: "), result);
  assert.ok(result.includes("fetch failed"), result);
});

test("deleteR2Object reports every failure as an error, whatever wrangler says about a key or a bucket that is not there", async () => {
  // Wrangler's wording for a miss on a remote bucket has never been seen. The database rows are the only list of which
  // objects exist, so a failure taken for a miss would delete them and orphan the objects for good.
  for (const stderr of [
    "The specified key does not exist. [code: 10007]",
    "NoSuchKey",
    "The specified bucket does not exist. [code: 10006]",
    "404 Not Found",
    "not found",
    "Not logged in.",
  ]) {
    const result = await deleteR2Object({
      run: async () => {
        throw failedRun({ key: "videos/x.mp4", stderr });
      },
      bucket: "marauders-videos-staging",
      key: "videos/x.mp4",
    });
    assert.ok(result.startsWith("error: "), `${stderr} -> ${result}`);
  }
});

test("deleteR2Object shows wrangler's stderr on one short line, else the message, and survives a rejection that is not an Error", async () => {
  const loud = await deleteR2Object({
    run: async () => {
      throw failedRun({ key: "k", stderr: `\n ✘ [ERROR] A request failed.\n\n   ${"x".repeat(500)}\n` });
    },
    bucket: "b",
    key: "k",
  });
  assert.ok(!loud.includes("\n"), "one line");
  assert.ok(loud.length <= "error: ".length + 200, `short: ${loud.length}`);
  assert.ok(loud.includes("A request failed."), loud);
  assert.ok(!loud.includes("Command failed"), "stderr rather than the command line when there is stderr");

  const noStderr = await deleteR2Object({
    run: async () => {
      throw new Error("spawn npx ENOENT");
    },
    bucket: "b",
    key: "k",
  });
  assert.equal(noStderr, "error: spawn npx ENOENT");

  const odd = await deleteR2Object({
    run: async () => {
      throw "boom";
    },
    bucket: "b",
    key: "k",
  });
  assert.equal(odd, "error: boom");
});

test("no script builds a wrangler r2 object command by hand", () => {
  const scriptsDir = path.join(BACKEND_DIR, "scripts");
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) walk(path.join(dir, entry.name));
      else if (entry.name.endsWith(".mjs")) files.push(path.join(dir, entry.name));
    }
  };
  walk(scriptsDir);
  assert.ok(files.length > 5);
  for (const file of files) {
    if (file === path.join(scriptsDir, "lib", "r2.mjs")) continue;
    const text = readFileSync(file, "utf8");
    assert.ok(!/["']r2["']\s*,\s*["']object["']/.test(text), `${path.relative(BACKEND_DIR, file)} must call r2ObjectArgs instead`);
  }
});

test("db:purge, video:hls and test-upload refuse a missing or unknown environment before doing anything", () => {
  const cases = [
    { script: "purge-videos.mjs", args: [], expect: "--env" },
    { script: "purge-videos.mjs", args: ["--env", "qa"], expect: "qa" },
    { script: "purge-videos.mjs", args: ["--env", "staging", "extra"], expect: "extra" },
    { script: "hls-transcode-r2.mjs", args: [], expect: "--env" },
    { script: "hls-transcode-r2.mjs", args: ["--env", "qa", UUID], expect: "qa" },
    { script: "hls-transcode-r2.mjs", args: ["--env", "staging"], expect: "feed_videos.id" },
    { script: "hls-transcode-r2.mjs", args: ["--env", "staging", "not-a-uuid"], expect: "feed_videos.id" },
    { script: "hls-transcode-r2.mjs", args: ["--env", "staging", UUID, "a.mp4", "extra"], expect: "extra" },
    { script: "test-upload.mjs", args: [], expect: "--env" },
    { script: "test-upload.mjs", args: ["--env", "qa"], expect: "qa" },
    { script: "test-upload.mjs", args: ["--env", "staging", "extra"], expect: "extra" },
  ];
  for (const { script, args, expect } of cases) {
    const run = spawnSync(process.execPath, [path.join(BACKEND_DIR, "scripts", script), ...args], { encoding: "utf8", timeout: 20000 });
    assert.equal(run.status, 2, `${script} ${args.join(" ")} -> ${run.stderr}`);
    assert.ok(run.stderr.startsWith("error: "), run.stderr);
    assert.ok(run.stderr.includes(expect), run.stderr);
    assert.ok(!run.stderr.includes("    at "), "no stack trace");
  }
});
