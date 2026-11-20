// Tests of backend/scripts/lib/purge.mjs: the order of a purge (count, ask, delete objects, delete rows) and what
// stops it. The database and the bucket are fakes; nothing here touches a network.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import test from "node:test";

import { purgeVideos } from "../../scripts/lib/purge.mjs";
import { UsageError, loadEnvironments } from "../../scripts/lib/targets.mjs";

const ENVIRONMENTS = loadEnvironments();
const UUID_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const UUID_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

/** One MP4 clip, one HLS clip (master + 200 segments to try) and one row that points outside our media route. */
function fixture(name, { deleteResult = () => "deleted", confirmFails = false } = {}) {
  const config = ENVIRONMENTS[name];
  const events = [];
  const deletions = [];
  const rows = [
    { id: "1", stream_url: `${config.url}/v1/media/videos/${UUID_A}.mp4` },
    { id: "2", stream_url: `${config.url}/v1/media/videos/${UUID_B}/master.m3u8` },
    { id: "3", stream_url: "https://elsewhere.example/clip.mp4" },
  ];
  const sql = async (strings) => {
    const text = strings.join("?").replace(/\s+/g, " ").trim();
    if (/^SELECT/i.test(text)) {
      events.push("select");
      return rows;
    }
    if (/^DELETE FROM feed_videos/i.test(text)) {
      events.push("delete-rows");
      return rows.map(({ id }) => ({ id }));
    }
    throw new Error(`unexpected statement: ${text}`);
  };
  const logs = [];
  return {
    config,
    events,
    deletions,
    logs,
    input: {
      sql,
      config,
      confirm: async (phrase) => {
        events.push(`confirm(${phrase})`);
        if (confirmFails) throw new UsageError("not confirmed");
      },
      deleteObject: async (bucket, key) => {
        if (!events.includes("delete-objects")) events.push("delete-objects");
        deletions.push({ bucket, key });
        return deleteResult(key);
      },
      log: (line) => logs.push(line),
    },
  };
}

test("a purge counts, then asks for its phrase, then deletes the objects, then the rows", async () => {
  const { input, events, logs } = fixture("staging");
  await purgeVideos(input);
  assert.deepEqual(events, ["select", "confirm(purge staging)", "delete-objects", "delete-rows"]);
  assert.ok(logs.some((line) => line.includes("feed_videos rows: 3")), logs.join("\n"));
  assert.ok(logs.some((line) => line.includes("202")), "the number of objects to try is shown before the question");
});

test("production asks for the production phrase", async () => {
  const { input, events } = fixture("production");
  await purgeVideos(input);
  assert.ok(events.includes("confirm(purge production)"), events.join(","));
});

test("a refused confirmation deletes nothing", async () => {
  const { input, events, deletions } = fixture("production", { confirmFails: true });
  await assert.rejects(purgeVideos(input), UsageError);
  assert.deepEqual(events, ["select", "confirm(purge production)"]);
  assert.deepEqual(deletions, []);
});

test("every delete goes to the environment's own bucket", async () => {
  for (const name of ["staging", "production"]) {
    const { input, deletions, config } = fixture(name);
    const result = await purgeVideos(input);
    assert.equal(deletions.length, 202);
    assert.ok(deletions.every((entry) => entry.bucket === config.bucket), `${name}: bucket`);
    assert.deepEqual(deletions[0], { bucket: config.bucket, key: `videos/${UUID_A}.mp4` });
    assert.deepEqual(deletions[1], { bucket: config.bucket, key: `videos/${UUID_B}/master.m3u8` });
    assert.deepEqual(deletions.at(-1), { bucket: config.bucket, key: `videos/${UUID_B}/seg199.ts` });
    assert.deepEqual(result, { rows: 3, keys: 202, deleted: 202, missing: 0, errors: 0, removed: 3 });
  }
});

test("missing objects are counted, not fatal", async () => {
  const { input } = fixture("staging", { deleteResult: (key) => (key.endsWith(".ts") ? "missing" : "deleted") });
  const result = await purgeVideos(input);
  assert.deepEqual(result, { rows: 3, keys: 202, deleted: 2, missing: 200, errors: 0, removed: 3 });
});

test("a failed object delete leaves the rows in place and fails the run", async () => {
  const { input, events } = fixture("staging", {
    deleteResult: (key) => (key === `videos/${UUID_A}.mp4` ? "error: not logged in" : "deleted"),
  });
  await assert.rejects(purgeVideos(input), (error) => /1 object/.test(error.message) && /left in place/.test(error.message));
  assert.ok(!events.includes("delete-rows"), "the rows are the only list of what to retry, so they stay");
});
