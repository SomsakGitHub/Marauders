import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { withAttempts } from "../src/retry";
import { deleteAvatarObject, deleteClipObjects, planClipObjects } from "../src/storage/clipObjects";
import { FakeBucket } from "./fakes/bucket";

// Lowercase uuids made up for the tests.
const U = "3f2a8c1e-5b7d-4e9a-8c1d-0a1b2c3d4e5f";
const V = "9d4c7b2a-1e3f-4a5b-9c8d-7e6f5a4b3c2d";

const media = (key: string) => `https://api.test/v1/media/${key}`;
const asR2 = (bucket: FakeBucket) => bucket as unknown as R2Bucket;
const keysOf = (bucket: FakeBucket) => [...bucket.objects.keys()].sort();

function bucketWith(...keys: string[]): FakeBucket {
  const bucket = new FakeBucket();
  for (const key of keys) {
    bucket.objects.set(key, "bytes");
  }
  return bucket;
}

describe("planClipObjects", () => {
  const cases: Array<[string, string, unknown]> = [
    ["a plain upload is one exact key", media(`videos/${U}.mp4`), { kind: "exact", key: `videos/${U}.mp4` }],
    ["an HLS playlist is everything under its uuid", media(`videos/${U}/master.m3u8`), { kind: "prefix", prefix: `videos/${U}` }],
    ["a file deeper under the uuid is the same prefix", media(`videos/${U}/hls/seg000.ts`), { kind: "prefix", prefix: `videos/${U}` }],
    ["a hand-made name is one exact key", media("videos/demo.mp4"), { kind: "exact", key: "videos/demo.mp4" }],
    ["a folder that is not a uuid is one exact key", media("videos/not-a-uuid/master.m3u8"), { kind: "exact", key: "videos/not-a-uuid/master.m3u8" }],
    [
      "an upper-case uuid is never a prefix",
      media(`videos/${U.toUpperCase()}/master.m3u8`),
      { kind: "exact", key: `videos/${U.toUpperCase()}/master.m3u8` },
    ],
    ["a URL outside /v1/media/ names nothing of ours", "https://elsewhere.test/videos/demo.mp4", { kind: "none" }],
    ["a key with two dots is refused", media("videos/../avatars/x.jpg"), { kind: "none" }],
    ["a key with a backslash is refused", media("videos\\x.mp4"), { kind: "none" }],
  ];
  for (const [name, url, plan] of cases) {
    it(name, () => {
      assert.deepEqual(planClipObjects(url), plan);
    });
  }
});

describe("deleteClipObjects", () => {
  it("deletes a plain clip and leaves the neighbour", async () => {
    const bucket = bucketWith(`videos/${U}.mp4`, `videos/${V}.mp4`);

    await deleteClipObjects(asR2(bucket), [media(`videos/${U}.mp4`)]);

    assert.deepEqual(keysOf(bucket), [`videos/${V}.mp4`]);
  });

  it("deletes every file of an HLS clip, page by page, and leaves the neighbour", async () => {
    const bucket = bucketWith(
      `videos/${U}/master.m3u8`,
      `videos/${U}/seg000.ts`,
      `videos/${U}/seg001.ts`,
      `videos/${U}/seg002.ts`,
      `videos/${U}.mov`,
      `videos/${V}/master.m3u8`,
    );
    bucket.pageSize = 2;

    await deleteClipObjects(asR2(bucket), [media(`videos/${U}/master.m3u8`)]);

    assert.deepEqual(keysOf(bucket), [`videos/${V}/master.m3u8`]);
    // Each page is deleted before the next one is read.
    assert.deepEqual(
      bucket.calls.map((call) => call.op),
      ["list", "delete", "list", "delete", "list", "delete"],
    );
  });

  it("deletes plain and HLS clips together and nothing else", async () => {
    const bucket = bucketWith(`videos/${U}.mp4`, `videos/${V}/master.m3u8`, `videos/${V}/seg000.ts`, "videos/keep.mp4");

    await deleteClipObjects(asR2(bucket), [media(`videos/${U}.mp4`), media(`videos/${V}/master.m3u8`)]);

    assert.deepEqual(keysOf(bucket), ["videos/keep.mp4"]);
  });

  it("sends 2,500 exact keys in deletes of at most 1,000", async () => {
    const names = Array.from({ length: 2500 }, (_, index) => `videos/clip-${String(index).padStart(4, "0")}.mp4`);
    const bucket = bucketWith(...names, "videos/keep.mp4");

    await deleteClipObjects(asR2(bucket), names.map(media));

    assert.deepEqual(keysOf(bucket), ["videos/keep.mp4"]);
    const sizes = bucket.calls.filter((call) => call.op === "delete").map((call) => (call.arg as string[]).length);
    assert.deepEqual(sizes, [1000, 1000, 500]);
  });

  it("makes no bucket call without URLs, or with URLs that name nothing of ours", async () => {
    const bucket = bucketWith("videos/keep.mp4");

    await deleteClipObjects(asR2(bucket), []);
    await deleteClipObjects(asR2(bucket), ["https://elsewhere.test/clip.mp4", media("videos/../x.mp4")]);

    assert.deepEqual(bucket.calls, []);
    assert.deepEqual(keysOf(bucket), ["videos/keep.mp4"]);
  });

  it("still succeeds when a delete fails twice", async () => {
    const bucket = bucketWith(`videos/${U}.mp4`);
    bucket.failNext("delete", 2);

    await deleteClipObjects(asR2(bucket), [media(`videos/${U}.mp4`)]);

    assert.deepEqual(keysOf(bucket), []);
  });

  it("rejects when a delete fails three times, and leaves the clip for the next try", async () => {
    const bucket = bucketWith(`videos/${U}.mp4`);
    bucket.failNext("delete", 3);

    await assert.rejects(deleteClipObjects(asR2(bucket), [media(`videos/${U}.mp4`)]), /delete failed/);

    assert.deepEqual(keysOf(bucket), [`videos/${U}.mp4`]);
  });

  it("retries a list that fails once", async () => {
    const bucket = bucketWith(`videos/${U}/master.m3u8`, `videos/${U}/seg000.ts`);
    bucket.failNext("list", 1);

    await deleteClipObjects(asR2(bucket), [media(`videos/${U}/master.m3u8`)]);

    assert.deepEqual(keysOf(bucket), []);
  });
});

describe("deleteAvatarObject", () => {
  it("deletes the avatar named by the URL", async () => {
    const bucket = bucketWith(`avatars/${U}.jpg`, `avatars/${V}.jpg`);

    await deleteAvatarObject(asR2(bucket), media(`avatars/${U}.jpg`));

    assert.deepEqual(keysOf(bucket), [`avatars/${V}.jpg`]);
  });

  const noCall: Array<[string, string | null]> = [
    ["no avatar", null],
    ["a URL outside /v1/media/", "https://elsewhere.test/avatars/x.jpg"],
    ["a key outside avatars/", media(`videos/${U}.mp4`)],
  ];
  for (const [name, url] of noCall) {
    it(`makes no bucket call for ${name}`, async () => {
      const bucket = bucketWith(`avatars/${U}.jpg`, `videos/${U}.mp4`);

      await deleteAvatarObject(asR2(bucket), url);

      assert.deepEqual(bucket.calls, []);
    });
  }
});

describe("withAttempts", () => {
  it("returns the first success without trying again", async () => {
    let calls = 0;
    const value = await withAttempts(async () => {
      calls += 1;
      return "done";
    }, 3, 0);
    assert.equal(value, "done");
    assert.equal(calls, 1);
  });

  it("tries again after a failure and returns the later success", async () => {
    let calls = 0;
    const value = await withAttempts(async () => {
      calls += 1;
      if (calls < 3) {
        throw new Error(`failure ${calls}`);
      }
      return "third time";
    }, 3, 0);
    assert.equal(value, "third time");
    assert.equal(calls, 3);
  });

  it("gives up after three tries and rethrows the last error", async () => {
    let calls = 0;
    await assert.rejects(
      withAttempts(async () => {
        calls += 1;
        throw new Error(`failure ${calls}`);
      }, undefined, 0),
      /failure 3/,
    );
    assert.equal(calls, 3);
  });

  it("honours another number of attempts", async () => {
    let calls = 0;
    await assert.rejects(
      withAttempts(async () => {
        calls += 1;
        throw new Error("always");
      }, 5, 0),
    );
    assert.equal(calls, 5);
  });
});
