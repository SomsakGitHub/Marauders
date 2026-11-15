import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { SignJWT } from "jose";

import { findFeedVideoByUploadKey, insertFeedVideo, UploadKeyConflictError } from "../src/db/feed";
import worker from "../src/index";
import { FeedValidationError, parseUploadIdempotencyKey } from "../src/validation";
import { queries, resetFakeNeon, respondWith, type Query } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is real.
const DB = "postgres://fake.invalid/test";
const JWT_SECRET = "upload-idempotency-test-signing-secret-0123456789abcdef";
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

const BOB = "22222222-2222-4222-8222-222222222222";
const WINNER_ID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

async function tokenFor(userId: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(JWT_SECRET));
}

/** A stand-in for the R2 bucket that remembers which objects were written and deleted. */
function fakeBucket() {
  const puts: string[] = [];
  const deletes: string[] = [];
  return {
    puts,
    deletes,
    put: async (objectKey: string) => {
      puts.push(objectKey);
    },
    delete: async (objectKey: string) => {
      deletes.push(objectKey);
    },
  };
}

function makeEnv() {
  const bucket = fakeBucket();
  const env = { DATABASE_URL: DB, JWT_SIGNING_SECRET: JWT_SECRET, VIDEOS: bucket } as never;
  return { env, bucket };
}

/** A POST to /v1/videos: with the multipart body of a 16 byte QuickTime clip, or with no body at all (a replay). */
async function uploadRequest(options: { userId?: string; key?: string; body?: boolean } = {}): Promise<Request> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${await tokenFor(options.userId ?? OWNER)}`,
  };
  if (options.key !== undefined) {
    headers["Idempotency-Key"] = options.key;
  }
  if (options.body === false) {
    return new Request("https://api.test/v1/videos", { method: "POST", headers });
  }
  const form = new FormData();
  form.set("latitude", "13.75");
  form.set("longitude", "100.5");
  form.set("file", new File([new Uint8Array(16)], "clip.mov", { type: "video/quicktime" }));
  return new Request("https://api.test/v1/videos", { method: "POST", headers, body: form });
}

type Script = {
  rateCount?: number;
  /** The rows a stored-key lookup returns. */
  lookup?: (query: Query) => unknown[];
  /** The rows the insert returns. */
  insert?: (query: Query) => unknown[];
};

function script(s: Script = {}): void {
  respondWith((query) => {
    if (/rate_limit_counters/.test(query.text)) return [{ count: s.rateCount ?? 1 }];
    if (/v\.upload_key = \?::uuid/.test(query.text)) return (s.lookup ?? (() => []))(query);
    if (/INSERT INTO feed_videos/.test(query.text)) return (s.insert ?? (() => [clipRow()]))(query);
    throw new Error(`unexpected statement: ${query.text}`);
  });
}

function recorded(pattern: RegExp): Query[] {
  return queries.filter((query) => pattern.test(query.text));
}

type ItemBody = { item: { id: string } };

describe("POST /v1/videos with an Idempotency-Key", () => {
  beforeEach(() => resetFakeNeon());

  it("aRequestWithoutTheHeaderRunsTodaysSql", async () => {
    script();
    const { env, bucket } = makeEnv();
    const res = await worker.fetch(await uploadRequest(), env);
    assert.equal(res.status, 201);
    assert.equal(queries.length, 2, "the rate limit and one insert");
    const inserts = recorded(/INSERT INTO feed_videos/);
    assert.equal(inserts.length, 1);
    assert.doesNotMatch(inserts[0].text, /upload_key/);
    assert.equal(bucket.puts.length, 1);
  });

  it("aHeaderThatIsNotAUuidIsRefusedBeforeAnythingIsReadOrStored", async () => {
    for (const key of ["not-a-uuid", ""]) {
      resetFakeNeon();
      script();
      const { env, bucket } = makeEnv();
      const request = await uploadRequest({ key });
      const res = await worker.fetch(request, env);
      assert.equal(res.status, 400, JSON.stringify(key));
      assert.deepEqual(await res.json(), { error: "Idempotency-Key must be a UUID" });
      assert.equal(request.bodyUsed, false, "the body is not read");
      assert.deepEqual(bucket.puts, []);
      assert.equal(recorded(/INSERT INTO feed_videos/).length, 0);
      assert.equal(recorded(/upload_key/).length, 0, "no lookup either");
    }
  });

  it("aKeyThatIsAlreadyStoredAnswers200WithTheStoredClipAndReadsNothing", async () => {
    script({ lookup: () => [clipRow()] });
    const { env, bucket } = makeEnv();
    const request = await uploadRequest({ key: KEY });
    const res = await worker.fetch(request, env);
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as ItemBody).item.id, CLIP_ID);
    assert.equal(request.bodyUsed, false, "the body is not read");
    assert.deepEqual(bucket.puts, []);
    assert.deepEqual(bucket.deletes, []);
    assert.equal(recorded(/INSERT INTO feed_videos/).length, 0);
  });

  it("aReplayWithoutABodyAnswersFromTheStoredKey", async () => {
    script({ lookup: () => [clipRow()] });
    const { env } = makeEnv();
    const res = await worker.fetch(await uploadRequest({ key: KEY, body: false }), env);
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as ItemBody).item.id, CLIP_ID);
  });

  it("aReplayWithoutABodyForAnUnknownKeyIsRefusedAndStoresNothing", async () => {
    script({ lookup: () => [] });
    const { env, bucket } = makeEnv();
    const res = await worker.fetch(await uploadRequest({ key: KEY, body: false }), env);
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { error: "expected multipart form data" });
    assert.equal(recorded(/v\.upload_key = \?::uuid/).length, 1, "the key was looked up before the body was checked");
    assert.deepEqual(bucket.puts, []);
    assert.equal(recorded(/INSERT INTO feed_videos/).length, 0);
  });

  it("aNewKeyIsStoredWithTheUploadAndAnswers201", async () => {
    script({ lookup: () => [] });
    const { env, bucket } = makeEnv();
    const res = await worker.fetch(await uploadRequest({ key: KEY.toUpperCase() }), env);
    assert.equal(res.status, 201);
    const insert = recorded(/INSERT INTO feed_videos/)[0];
    assert.ok(insert, "the clip is inserted");
    assert.ok(insert.values.includes(KEY), "the key is stored in lower case");
    assert.ok(!insert.values.includes(KEY.toUpperCase()));
    assert.match(flat(insert.text), /ON CONFLICT \(owner_user_id, upload_key\)/);
    assert.equal(bucket.puts.length, 1);
  });

  it("twoRequestsWithOneKeyLeaveOneClipAndTheLoserDeletesItsObject", async () => {
    // The first lookup finds nothing, the insert then loses to the request that stored the key, and the second lookup
    // finds the winner's clip.
    const lookups: unknown[][] = [[], [{ ...clipRow(), id: WINNER_ID }]];
    script({ lookup: () => lookups.shift() ?? [], insert: () => [] });
    const { env, bucket } = makeEnv();
    const res = await worker.fetch(await uploadRequest({ key: KEY }), env);
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as ItemBody).item.id, WINNER_ID);
    assert.equal(bucket.puts.length, 1);
    assert.deepEqual(bucket.deletes, bucket.puts, "the object this request wrote is gone");
  });

  it("aLoserWhoseWinnerWasDeletedAnswers500AndLeavesNoObject", async () => {
    script({ lookup: () => [], insert: () => [] });
    const { env, bucket } = makeEnv();
    const res = await worker.fetch(await uploadRequest({ key: KEY }), env);
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "database write failed: upload key conflict" });
    assert.equal(bucket.puts.length, 1);
    assert.deepEqual(bucket.deletes, bucket.puts, "the object this request wrote is gone");
  });

  it("aKeyBelongsToTheAccountThatSentIt", async () => {
    // Only OWNER holds KEY: the lookup finds the clip for OWNER's id and nothing for anyone else's.
    script({
      lookup: (query) => (query.values[0] === OWNER ? [clipRow()] : []),
      insert: () => [{ ...clipRow(), id: WINNER_ID }],
    });

    const first = makeEnv();
    const ownersReplay = await worker.fetch(await uploadRequest({ userId: OWNER, key: KEY }), first.env);
    assert.equal(ownersReplay.status, 200);
    assert.equal(((await ownersReplay.json()) as ItemBody).item.id, CLIP_ID);

    resetFakeNeon();
    script({
      lookup: (query) => (query.values[0] === OWNER ? [clipRow()] : []),
      insert: () => [{ ...clipRow(), id: WINNER_ID }],
    });
    const second = makeEnv();
    const bobsUpload = await worker.fetch(await uploadRequest({ userId: BOB, key: KEY }), second.env);
    assert.equal(bobsUpload.status, 201, "the same key from another account is a new key");
    assert.equal(((await bobsUpload.json()) as ItemBody).item.id, WINNER_ID);
    assert.equal(recorded(/v\.upload_key = \?::uuid/)[0].values[0], BOB);
    assert.ok(recorded(/INSERT INTO feed_videos/)[0].values.includes(BOB));
    assert.equal(second.bucket.puts.length, 1);
  });

  it("aFailedLookupAnswers500AndStoresNothing", async () => {
    script({
      lookup: () => {
        throw new Error("connection refused secret-detail");
      },
    });
    const { env, bucket } = makeEnv();
    const request = await uploadRequest({ key: KEY });
    const res = await worker.fetch(request, env);
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "upload lookup failed" });
    assert.equal(request.bodyUsed, false, "the body is not read");
    assert.deepEqual(bucket.puts, []);
    assert.equal(recorded(/INSERT INTO feed_videos/).length, 0);
  });

  it("aReplayCountsAgainstTheUploadRateLimit", async () => {
    script({ rateCount: 11, lookup: () => [clipRow()] });
    const { env } = makeEnv();
    const res = await worker.fetch(await uploadRequest({ key: KEY, body: false }), env);
    assert.equal(res.status, 429);
    assert.equal(recorded(/upload_key/).length, 0, "no lookup ran");
  });
});
