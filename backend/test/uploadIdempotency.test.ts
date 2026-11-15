import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { findFeedVideoByUploadKey, insertFeedVideo, UploadKeyConflictError } from "../src/db/feed";
import { FeedValidationError, parseUploadIdempotencyKey } from "../src/validation";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is real.
const DB = "postgres://fake.invalid/test";
const OWNER = "11111111-1111-4111-8111-111111111111";
const KEY = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const CLIP_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const STREAM_URL = "https://api.test/v1/media/videos/x.mov";

/** The columns a stored clip's card is read from, as the database would return them. */
function clipRow() {
  return {
    id: CLIP_ID,
    stream_url: STREAM_URL,
    latitude: 13.75,
    longitude: 100.5,
    author_name: "@alice",
    avatar_url: null,
    caption: "",
    audio_assessment: null,
  };
}

/** The text of a recorded statement with its runs of whitespace folded to one space. */
function flat(text: string): string {
  return text.replace(/\s+/g, " ");
}

describe("the upload key in the database layer", () => {
  beforeEach(() => resetFakeNeon());

  it("parseUploadIdempotencyKeyRefusesWhatIsNotAUuid", () => {
    assert.equal(parseUploadIdempotencyKey(null), null);
    assert.equal(parseUploadIdempotencyKey(KEY.toUpperCase()), KEY);
    for (const bad of ["", "abc", `{${KEY}}`, `${KEY} `, `${KEY}a`]) {
      assert.throws(
        () => parseUploadIdempotencyKey(bad),
        (error: unknown) =>
          error instanceof FeedValidationError && error.message === "Idempotency-Key must be a UUID",
        JSON.stringify(bad),
      );
    }
  });

  it("insertWithoutAKeyRunsTodaysStatement", async () => {
    respondWith(() => [clipRow()]);
    await insertFeedVideo(DB, STREAM_URL, 1, 2, OWNER);
    assert.equal(queries.length, 1);
    assert.match(queries[0].text, /INSERT INTO feed_videos/);
    assert.doesNotMatch(queries[0].text, /upload_key/);
    assert.doesNotMatch(queries[0].text, /ON CONFLICT/);
  });

  it("insertWithAKeyStoresItAndSurvivesARace", async () => {
    respondWith(() => [clipRow()]);
    const item = await insertFeedVideo(DB, STREAM_URL, 1, 2, OWNER, "", null, KEY);
    assert.equal(queries.length, 1);
    assert.match(
      flat(queries[0].text),
      /ON CONFLICT \(owner_user_id, upload_key\) WHERE upload_key IS NOT NULL DO NOTHING/,
    );
    assert.ok(queries[0].values.includes(KEY), "the key is a value of the statement");
    assert.ok(queries[0].values.includes(OWNER), "the owner is a value of the statement");
    assert.equal(item.postedByViewer, true);

    // No row back: another request with the same key won the insert.
    resetFakeNeon();
    respondWith(() => []);
    await assert.rejects(insertFeedVideo(DB, STREAM_URL, 1, 2, OWNER, "", null, KEY), UploadKeyConflictError);
  });

  it("findFeedVideoByUploadKeyScopesByOwnerAndKey", async () => {
    respondWith(() => [clipRow()]);
    const item = await findFeedVideoByUploadKey(DB, OWNER, KEY);
    assert.equal(queries.length, 1);
    assert.match(flat(queries[0].text), /WHERE v\.owner_user_id = \?::uuid AND v\.upload_key = \?::uuid/);
    assert.deepEqual(queries[0].values, [OWNER, KEY]);
    assert.ok(item, "a stored clip is found");
    assert.equal(item.id, CLIP_ID);
    assert.equal(item.likeCount, 0);
    assert.equal(item.commentCount, 0);
    assert.equal(item.postedByViewer, true);

    resetFakeNeon();
    respondWith(() => []);
    assert.equal(await findFeedVideoByUploadKey(DB, OWNER, KEY), null);
  });
});
