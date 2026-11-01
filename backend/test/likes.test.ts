import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { SignJWT } from "jose";

import worker from "../src/index";
import { insertFeedVideo, listFeedVideos, listUserFeedVideos } from "../src/db/feed";
import { handleLikeChange } from "../src/routes/likes";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const JWT_SECRET = "likes-test-signing-secret-0123456789abcdef";
const VIEWER = "11111111-1111-4111-8111-111111111111";
const VIDEO = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_VIDEO = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

const env = { DATABASE_URL: "postgres://fake.invalid/test", JWT_SIGNING_SECRET: JWT_SECRET } as never;

async function tokenFor(userId: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(JWT_SECRET));
}

async function call(method: string, path: string, token: string | null = null): Promise<Response> {
  const headers: Record<string, string> = token ? { Authorization: `Bearer ${token}` } : {};
  return worker.fetch(new Request(`https://api.test${path}`, { method, headers }), env);
}

type Script = {
  likeRow?: { video_exists: number; like_count: number } | null;
  changeError?: Error;
  feedRows?: unknown[];
  likedRows?: unknown[];
  rateCount?: number;
};

function script(s: Script = {}): void {
  respondWith((query) => {
    if (/rate_limit_counters/.test(query.text)) return [{ count: s.rateCount ?? 1 }];
    if (/INSERT INTO video_likes|DELETE FROM video_likes/.test(query.text)) {
      if (s.changeError) throw s.changeError;
      return s.likeRow === null ? [] : [s.likeRow ?? { video_exists: 1, like_count: 1 }];
    }
    if (/FROM video_likes WHERE user_id/.test(query.text)) return s.likedRows ?? [];
    if (/FROM feed_videos v/.test(query.text)) return s.feedRows ?? [];
    throw new Error(`unexpected statement: ${query.text}`);
  });
}

function statement(pattern: RegExp) {
  return queries.find((query) => pattern.test(query.text));
}

function databaseError(code: string, constraint?: string): Error {
  return Object.assign(new Error(`database failure ${code} secret-detail`), { code, constraint });
}

function feedRow(id: string, likeCount: number) {
  return {
    id, stream_url: "https://media.test/clip.m3u8", latitude: null, longitude: null, country: "TH",
    author_name: "alice", avatar_url: null, caption: null, audio_assessment: null, like_count: likeCount,
  };
}

describe("PUT and DELETE /v1/videos/:id/like", () => {
  beforeEach(() => resetFakeNeon());

  it("likes a clip and answers the server's count", async () => {
    script({ likeRow: { video_exists: 1, like_count: 4 } });
    const res = await call("PUT", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.deepEqual(await res.json(), { liked: true, likeCount: 4 });
    const insert = statement(/INSERT INTO video_likes/);
    assert.ok(insert, "a like inserts a row");
    assert.match(insert.text, /ON CONFLICT \(video_id, user_id\) DO NOTHING/);
    assert.ok(insert.values.includes(VIEWER) && insert.values.includes(VIDEO));
    // A repeated like inserts nothing and must not count twice: the CTE adds only what it inserted.
    assert.match(insert.text.replace(/\s+/g, " "), /\+ \(SELECT count\(\*\) FROM changed\)/);
  });

  it("takes a like back and answers the count without it", async () => {
    script({ likeRow: { video_exists: 1, like_count: 3 } });
    const res = await call("DELETE", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { liked: false, likeCount: 3 });
    const removal = statement(/DELETE FROM video_likes/);
    assert.ok(removal, "an unlike deletes the viewer's row");
    assert.match(removal.text, /user_id = \?::uuid/);
    assert.ok(removal.values.includes(VIEWER));
    assert.match(removal.text.replace(/\s+/g, " "), /- \(SELECT count\(\*\) FROM changed\)/);
    assert.equal(statement(/INSERT INTO video_likes/), undefined);
  });

  it("does not take the route of deleting the clip", async () => {
    script();
    await call("DELETE", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER));
    assert.equal(statement(/DELETE FROM feed_videos/), undefined);
  });

  it("needs a signed-in viewer", async () => {
    script();
    for (const method of ["PUT", "DELETE"]) {
      const res = await call(method, `/v1/videos/${VIDEO}/like`);
      assert.equal(res.status, 401, method);
    }
    assert.equal((await call("PUT", `/v1/videos/${VIDEO}/like`, "not-a-token")).status, 401);
    assert.equal(queries.length, 0);
  });

  it("answers 404 for a clip that is gone", async () => {
    script({ likeRow: { video_exists: 0, like_count: 0 } });
    assert.equal((await call("PUT", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER))).status, 404);
    script({ likeRow: null });
    assert.equal((await call("DELETE", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER))).status, 404);
    script({ changeError: databaseError("23503", "video_likes_video_id_fkey") });
    assert.equal((await call("PUT", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER))).status, 404);
  });

  it("answers 401 when the token outlived its account", async () => {
    script({ changeError: databaseError("23503", "video_likes_user_id_fkey") });
    const res = await call("PUT", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER));
    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: "account not found" });
  });

  it("hides the database's message on other failures", async (t) => {
    t.mock.method(console, "error", () => {});
    script({ changeError: databaseError("57P01") });
    const res = await call("PUT", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER));
    assert.equal(res.status, 500);
    assert.doesNotMatch(await res.text(), /secret-detail/);
  });

  it("refuses an id that is not a UUID", async () => {
    script();
    assert.equal((await call("PUT", "/v1/videos/not-a-uuid/like", await tokenFor(VIEWER))).status, 400);
  });

  it("is not a like for any other verb", async () => {
    script();
    const token = await tokenFor(VIEWER);
    for (const method of ["POST", "PATCH"]) {
      assert.equal((await call(method, `/v1/videos/${VIDEO}/like`, token)).status, 405, method);
    }
    assert.equal((await call("GET", `/v1/videos/${VIDEO}/like`, token)).status, 404);
    assert.equal(queries.length, 0, "nothing may reach the database");
  });

  it("limits likes per viewer", async () => {
    script({ rateCount: 61 });
    const res = await call("PUT", `/v1/videos/${VIDEO}/like`, await tokenFor(VIEWER));
    assert.equal(res.status, 429);
    assert.ok(res.headers.get("retry-after"));
    assert.equal(statement(/INSERT INTO video_likes/), undefined);
    const limit = statement(/rate_limit_counters/);
    assert.ok(limit?.values.includes(`like:${VIEWER}`));
  });
});

describe("GET /v1/feed like fields", () => {
  beforeEach(() => resetFakeNeon());

  it("carries the count and whether the signed-in viewer likes each clip", async () => {
    script({ feedRows: [feedRow(VIDEO, 2), feedRow(OTHER_VIDEO, 0)], likedRows: [{ video_id: VIDEO.toUpperCase() }] });
    const res = await call("GET", "/v1/feed?limit=2", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    const items = ((await res.json()) as { items: { id: string; likeCount: number; likedByViewer: boolean }[] }).items;
    assert.deepEqual(items.map(({ id, likeCount, likedByViewer }) => ({ id, likeCount, likedByViewer })), [
      { id: VIDEO, likeCount: 2, likedByViewer: true },
      { id: OTHER_VIDEO, likeCount: 0, likedByViewer: false },
    ]);
    const liked = statement(/FROM video_likes WHERE user_id/);
    assert.deepEqual(liked?.values, [VIEWER, [VIDEO, OTHER_VIDEO]]);
    // The feed query itself does not know the viewer.
    assert.ok(!statement(/FROM feed_videos v/)?.values.includes(VIEWER));
  });

  it("matches clips to the viewer's likes whatever the case of the ids", async () => {
    script({ feedRows: [feedRow(VIDEO.toUpperCase(), 1)], likedRows: [{ video_id: VIDEO }] });
    const res = await call("GET", "/v1/feed?limit=2", await tokenFor(VIEWER));
    const items = ((await res.json()) as { items: { likedByViewer: boolean }[] }).items;
    assert.deepEqual(items.map(item => item.likedByViewer), [true]);
  });

  it("asks nothing about likes for a guest", async () => {
    script({ feedRows: [feedRow(VIDEO, 5)] });
    const res = await call("GET", "/v1/feed?limit=2");
    const items = ((await res.json()) as { items: { likeCount: number; likedByViewer: boolean }[] }).items;
    assert.deepEqual(items.map(({ likeCount, likedByViewer }) => ({ likeCount, likedByViewer })), [{ likeCount: 5, likedByViewer: false }]);
    assert.equal(statement(/FROM video_likes WHERE user_id/), undefined);
  });
});

describe("edges", () => {
  beforeEach(() => resetFakeNeon());

  it("answers 503 and asks nothing when the database is not configured", async () => {
    script();
    const res = await handleLikeChange({} as never, VIDEO, VIEWER, true);
    assert.equal(res.status, 503);
    assert.equal(queries.length, 0);
  });

  it("asks nothing about likes when a signed-in viewer's feed is empty", async () => {
    script({ feedRows: [] });
    const res = await call("GET", "/v1/feed?limit=2", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.deepEqual(((await res.json()) as { items: unknown[] }).items, []);
    assert.equal(statement(/FROM video_likes WHERE user_id/), undefined);
  });

  it("lists PUT among the methods a preflight allows", async () => {
    const res = await call("OPTIONS", `/v1/videos/${VIDEO}/like`);
    assert.equal(res.status, 204);
    assert.match(res.headers.get("access-control-allow-methods") ?? "", /\bPUT\b/);
  });
});

describe("queries that list clips", () => {
  beforeEach(() => resetFakeNeon());
  const DATABASE = "postgres://fake.invalid/test";
  const COUNT_SUBQUERY = /\(SELECT count\(\*\) FROM video_likes l WHERE l\.video_id = v\.id\)::int AS like_count/;
  const folded = () => queries.map(query => query.text.replace(/\s+/g, " "));

  it("count the likes of every clip the feed lists, with or without a cursor", async () => {
    for (const cursor of [null, OTHER_VIDEO]) {
      resetFakeNeon();
      respondWith(() => [feedRow(VIDEO, 7)]);
      const items = await listFeedVideos(DATABASE, 5, cursor);
      assert.equal(queries.length, 1);
      assert.match(folded()[0], COUNT_SUBQUERY, `cursor=${cursor}`);
      assert.deepEqual(items.map(({ likeCount, likedByViewer }) => ({ likeCount, likedByViewer })), [{ likeCount: 7, likedByViewer: false }]);
    }
  });

  it("count the likes of every clip on a profile", async () => {
    respondWith(() => [feedRow(VIDEO, 2)]);
    const items = await listUserFeedVideos(DATABASE, VIEWER, 50);
    assert.match(folded()[0], COUNT_SUBQUERY);
    assert.deepEqual(items.map(({ likeCount, likedByViewer }) => ({ likeCount, likedByViewer })), [{ likeCount: 2, likedByViewer: false }]);
  });

  it("report a clip that arrives without a count as having none", async () => {
    respondWith(() => [{ ...feedRow(VIDEO, 0), like_count: undefined }]);
    const items = await listFeedVideos(DATABASE, 5, null);
    assert.equal(items[0].likeCount, 0);
  });

  it("start a new upload with no likes", async () => {
    respondWith(() => [{
      id: VIDEO, stream_url: "https://media.test/clip.mp4", latitude: 1, longitude: 2,
      author_name: "alice", avatar_url: null, caption: "", audio_assessment: null,
    }]);
    const item = await insertFeedVideo(DATABASE, "https://media.test/clip.mp4", 1, 2, VIEWER);
    assert.deepEqual({ likeCount: item.likeCount, likedByViewer: item.likedByViewer }, { likeCount: 0, likedByViewer: false });
  });
});
