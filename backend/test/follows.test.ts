import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { SignJWT } from "jose";

import worker from "../src/index";
import { insertFeedVideo } from "../src/db/feed";
import { authorRelations, handleFollowChange } from "../src/routes/follows";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const JWT_SECRET = "follows-test-signing-secret-0123456789abcdef";
const VIEWER = "11111111-1111-4111-8111-111111111111";
const ALICE = "22222222-2222-4222-8222-222222222222";
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
  followRow?: { target_id: string | null; follower_count: number; viewer_following_count: number } | null;
  changeError?: Error;
  accountRows?: unknown[];
  meRows?: unknown[];
  feedRows?: unknown[];
  likedRows?: unknown[];
  relationRows?: unknown[];
  rateCount?: number;
};

/** Answers each statement the routes run, told apart by their SQL text. */
function script(s: Script = {}): void {
  respondWith((query) => {
    if (/rate_limit_counters/.test(query.text)) return [{ count: s.rateCount ?? 1 }];
    if (/INSERT INTO user_follows|DELETE FROM user_follows/.test(query.text)) {
      if (s.changeError) throw s.changeError;
      return s.followRow === null ? [] : [s.followRow ?? { target_id: ALICE, follower_count: 1, viewer_following_count: 1 }];
    }
    if (/AS posted_by_viewer/.test(query.text)) return s.relationRows ?? [];
    if (/FROM video_likes WHERE user_id/.test(query.text)) return s.likedRows ?? [];
    if (/WHERE u\.handle = \?/.test(query.text)) return s.accountRows ?? [];
    if (/WHERE u\.id = \?::uuid/.test(query.text)) return s.meRows ?? [];
    if (/FROM feed_videos v/.test(query.text)) return s.feedRows ?? [];
    throw new Error(`unexpected statement: ${query.text}`);
  });
}

function statement(pattern: RegExp) {
  return queries.find((query) => pattern.test(query.text));
}

const folded = (text: string) => text.replace(/\s+/g, " ");

function databaseError(code: string, constraint?: string): Error {
  return Object.assign(new Error(`database failure ${code} secret-detail`), { code, constraint });
}

function feedRow(id: string) {
  return {
    id, stream_url: "https://media.test/clip.m3u8", latitude: null, longitude: null, country: "TH",
    author_name: "@alice", avatar_url: null, caption: null, audio_assessment: null, like_count: 0, comment_count: 0,
  };
}

function accountRow(overrides: Record<string, unknown> = {}) {
  return {
    id: ALICE, handle: "@alice", country: "TH", avatar_url: null, video_count: 1,
    follower_count: 3, following_count: 5, followed_by_viewer: false, ...overrides,
  };
}

describe("PUT and DELETE /v1/users/:handle/follow", () => {
  beforeEach(() => resetFakeNeon());

  it("follows an account and answers the server's counts", async () => {
    script({ followRow: { target_id: ALICE, follower_count: 4, viewer_following_count: 9 } });
    const res = await call("PUT", "/v1/users/@alice/follow", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.deepEqual(await res.json(), { following: true, followerCount: 4, viewerFollowingCount: 9 });
    const insert = statement(/INSERT INTO user_follows/);
    assert.ok(insert, "a follow inserts a row");
    assert.match(insert.text, /ON CONFLICT \(follower_user_id, followed_user_id\) DO NOTHING/);
    assert.ok(insert.values.includes(VIEWER) && insert.values.includes("@alice"));
    // The viewer's own handle writes nothing.
    assert.match(folded(insert.text), /FROM target WHERE id <> \?::uuid/);
    // A repeated follow inserts nothing and must not count twice: the CTE adds only what it inserted.
    assert.equal(folded(insert.text).match(/\+ \(SELECT count\(\*\) FROM changed\)/g)?.length, 2);
  });

  it("stops following and answers the counts without the row", async () => {
    script({ followRow: { target_id: ALICE, follower_count: 2, viewer_following_count: 0 } });
    const res = await call("DELETE", "/v1/users/@alice/follow", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { following: false, followerCount: 2, viewerFollowingCount: 0 });
    const removal = statement(/DELETE FROM user_follows/);
    assert.ok(removal, "an unfollow deletes the viewer's row");
    assert.match(folded(removal.text), /WHERE follower_user_id = \?::uuid AND followed_user_id = \(SELECT id FROM target\)/);
    assert.ok(removal.values.includes(VIEWER));
    assert.equal(folded(removal.text).match(/- \(SELECT count\(\*\) FROM changed\)/g)?.length, 2);
    assert.equal(statement(/INSERT INTO user_follows/), undefined);
  });

  it("finds the account by its handle whatever the case, with or without the @", async () => {
    for (const path of ["/v1/users/%40Alice/follow", "/v1/users/ALICE/follow", "/v1/users/@alice/follow"]) {
      resetFakeNeon();
      script();
      assert.equal((await call("PUT", path, await tokenFor(VIEWER))).status, 200, path);
      assert.ok(statement(/INSERT INTO user_follows/)?.values.includes("@alice"), path);
    }
  });

  it("needs a signed-in viewer", async () => {
    script();
    for (const method of ["PUT", "DELETE"]) {
      assert.equal((await call(method, "/v1/users/@alice/follow")).status, 401, method);
    }
    assert.equal((await call("PUT", "/v1/users/@alice/follow", "not-a-token")).status, 401);
    assert.equal(queries.length, 0);
  });

  it("answers 404 for an account that is not there", async () => {
    script({ followRow: { target_id: null, follower_count: 0, viewer_following_count: 2 } });
    assert.equal((await call("PUT", "/v1/users/@nobody/follow", await tokenFor(VIEWER))).status, 404);
    script({ followRow: null });
    assert.equal((await call("DELETE", "/v1/users/@nobody/follow", await tokenFor(VIEWER))).status, 404);
    script({ changeError: databaseError("23503", "user_follows_followed_user_id_fkey") });
    const res = await call("PUT", "/v1/users/@alice/follow", await tokenFor(VIEWER));
    assert.equal(res.status, 404);
    assert.deepEqual(await res.json(), { error: "profile not found" });
  });

  it("answers 401 when the token outlived its account", async () => {
    script({ changeError: databaseError("23503", "user_follows_follower_user_id_fkey") });
    const res = await call("PUT", "/v1/users/@alice/follow", await tokenFor(VIEWER));
    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: "account not found" });
  });

  it("refuses to follow or unfollow the viewer themself", async () => {
    for (const method of ["PUT", "DELETE"]) {
      script({ followRow: { target_id: VIEWER.toUpperCase(), follower_count: 0, viewer_following_count: 0 } });
      const res = await call(method, "/v1/users/@me_myself/follow", await tokenFor(VIEWER));
      assert.equal(res.status, 422, method);
      assert.deepEqual(await res.json(), { error: "cannot follow yourself" });
    }
  });

  it("hides the database's message on other failures", async (t) => {
    t.mock.method(console, "error", () => {});
    script({ changeError: databaseError("57P01") });
    const res = await call("PUT", "/v1/users/@alice/follow", await tokenFor(VIEWER));
    assert.equal(res.status, 500);
    assert.doesNotMatch(await res.text(), /secret-detail/);
  });

  it("refuses a handle that cannot be one", async () => {
    script();
    const token = await tokenFor(VIEWER);
    for (const path of ["/v1/users/al%20ice/follow", "/v1/users/@me/follow", "/v1/users/%E0%A4%A/follow", `/v1/users/${"a".repeat(64)}/follow`]) {
      const res = await call("PUT", path, token);
      assert.equal(res.status, 400, path);
    }
    assert.equal(statement(/user_follows/), undefined, "nothing may be written");
  });

  it("is not a follow for any other verb", async () => {
    script();
    const token = await tokenFor(VIEWER);
    for (const method of ["POST", "PATCH"]) {
      assert.equal((await call(method, "/v1/users/@alice/follow", token)).status, 405, method);
    }
    // A GET is a profile lookup, and "@alice/follow" is no handle.
    assert.equal((await call("GET", "/v1/users/@alice/follow", token)).status, 400);
    assert.equal(queries.length, 0, "nothing may reach the database");
  });

  it("limits follows per viewer", async () => {
    script({ rateCount: 31 });
    const res = await call("PUT", "/v1/users/@alice/follow", await tokenFor(VIEWER));
    assert.equal(res.status, 429);
    assert.ok(res.headers.get("retry-after"));
    assert.equal(statement(/INSERT INTO user_follows/), undefined);
    assert.ok(statement(/rate_limit_counters/)?.values.includes(`follow:${VIEWER}`));
  });

  it("answers 503 and asks nothing when the database is not configured", async () => {
    script();
    const res = await handleFollowChange({} as never, "@alice", VIEWER, true);
    assert.equal(res.status, 503);
    assert.equal(queries.length, 0);
  });
});

describe("GET /v1/users/:handle follow fields", () => {
  beforeEach(() => resetFakeNeon());

  it("counts the account's followers and follows for a guest, who follows nobody", async () => {
    script({ accountRows: [accountRow()], feedRows: [feedRow(VIDEO)] });
    const res = await call("GET", "/v1/users/@alice");
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, unknown> & { videos: Record<string, unknown>[] };
    assert.deepEqual(
      { followerCount: body.followerCount, followingCount: body.followingCount, followedByViewer: body.followedByViewer, isViewer: body.isViewer },
      { followerCount: 3, followingCount: 5, followedByViewer: false, isViewer: false },
    );
    assert.deepEqual(body.videos.map(video => [video.postedByViewer, video.authorFollowedByViewer]), [[false, false]]);
    const lookup = statement(/WHERE u\.handle = \?/);
    assert.match(folded(lookup!.text), /\(SELECT count\(\*\) FROM user_follows f WHERE f\.followed_user_id = u\.id\)::int AS follower_count/);
    assert.match(folded(lookup!.text), /\(SELECT count\(\*\) FROM user_follows f WHERE f\.follower_user_id = u\.id\)::int AS following_count/);
    assert.deepEqual(lookup!.values, [null, "@alice"], "a guest is asked about as nobody");
  });

  it("tells a signed-in viewer whether they follow the account", async () => {
    script({ accountRows: [accountRow({ followed_by_viewer: true })], feedRows: [feedRow(VIDEO)] });
    const res = await call("GET", "/v1/users/@alice", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, unknown> & { videos: Record<string, unknown>[] };
    assert.equal(body.followedByViewer, true);
    assert.equal(body.isViewer, false);
    assert.deepEqual(body.videos.map(video => [video.postedByViewer, video.authorFollowedByViewer]), [[false, true]]);
    assert.deepEqual(statement(/WHERE u\.handle = \?/)?.values, [VIEWER, "@alice"]);
  });

  it("tells a viewer when the profile is their own, whatever the case of the ids", async () => {
    script({ accountRows: [accountRow({ id: VIEWER.toUpperCase() })], feedRows: [feedRow(VIDEO)] });
    const res = await call("GET", "/v1/users/@alice", await tokenFor(VIEWER));
    const body = (await res.json()) as Record<string, unknown> & { videos: Record<string, unknown>[] };
    assert.equal(body.isViewer, true);
    assert.deepEqual(body.videos.map(video => video.postedByViewer), [true]);
  });

  it("refuses a session that is supplied but not valid instead of answering as a guest", async () => {
    script({ accountRows: [accountRow()] });
    const res = await call("GET", "/v1/users/@alice", "not-a-token");
    assert.equal(res.status, 401);
    assert.equal(queries.length, 0);
  });

  it("refuses a handle whose escapes do not decode", async () => {
    script();
    assert.equal((await call("GET", "/v1/users/%E0%A4%A")).status, 400);
    assert.equal(queries.length, 0);
  });

  it("reads counts the database sends as text as numbers", async () => {
    script({ accountRows: [accountRow({ follower_count: "12", following_count: "0" })], feedRows: [] });
    const body = (await (await call("GET", "/v1/users/@alice")).json()) as Record<string, unknown>;
    assert.deepEqual([body.followerCount, body.followingCount], [12, 0]);
  });
});

describe("GET /v1/users/me follow fields", () => {
  beforeEach(() => resetFakeNeon());

  it("counts the viewer's followers and follows, and marks their clips as theirs", async () => {
    script({
      meRows: [{
        id: VIEWER, handle: "@viewer", country: "TH", avatar_url: null, latitude: null, longitude: null,
        location_updated_at: null, video_count: 1, follower_count: 7, following_count: 2,
      }],
      feedRows: [feedRow(VIDEO)],
    });
    const res = await call("GET", "/v1/users/me", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, unknown> & { videos: Record<string, unknown>[] };
    assert.deepEqual([body.followerCount, body.followingCount], [7, 2]);
    assert.deepEqual(body.videos.map(video => video.postedByViewer), [true]);
    const lookup = statement(/WHERE u\.id = \?::uuid/);
    assert.match(folded(lookup!.text), /FROM user_follows f WHERE f\.followed_user_id = u\.id\)::int AS follower_count/);
    assert.match(folded(lookup!.text), /FROM user_follows f WHERE f\.follower_user_id = u\.id\)::int AS following_count/);
  });
});

describe("GET /v1/feed follow fields", () => {
  beforeEach(() => resetFakeNeon());

  it("tells the signed-in viewer which clips they posted and whose authors they follow", async () => {
    script({
      feedRows: [feedRow(VIDEO), feedRow(OTHER_VIDEO)],
      relationRows: [
        { video_id: VIDEO.toUpperCase(), posted_by_viewer: false, author_followed: true },
        { video_id: OTHER_VIDEO, posted_by_viewer: true, author_followed: false },
      ],
    });
    const res = await call("GET", "/v1/feed?limit=2", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    const items = ((await res.json()) as { items: Record<string, unknown>[] }).items;
    assert.deepEqual(items.map(({ id, postedByViewer, authorFollowedByViewer }) => ({ id, postedByViewer, authorFollowedByViewer })), [
      { id: VIDEO, postedByViewer: false, authorFollowedByViewer: true },
      { id: OTHER_VIDEO, postedByViewer: true, authorFollowedByViewer: false },
    ]);
    const relations = statement(/AS posted_by_viewer/);
    assert.deepEqual(relations?.values, [VIEWER, VIEWER, [VIDEO, OTHER_VIDEO]]);
    // The feed query itself does not know the viewer.
    assert.ok(!statement(/FROM feed_videos v\s+LEFT JOIN/)?.values.includes(VIEWER));
  });

  it("leaves a clip the lookup did not answer for as neither", async () => {
    script({ feedRows: [feedRow(VIDEO)], relationRows: [] });
    const items = ((await (await call("GET", "/v1/feed?limit=2", await tokenFor(VIEWER))).json()) as { items: Record<string, unknown>[] }).items;
    assert.deepEqual(items.map(item => [item.postedByViewer, item.authorFollowedByViewer]), [[false, false]]);
  });

  it("asks nothing about follows for a guest", async () => {
    script({ feedRows: [feedRow(VIDEO)] });
    const items = ((await (await call("GET", "/v1/feed?limit=2")).json()) as { items: Record<string, unknown>[] }).items;
    assert.deepEqual(items.map(item => [item.postedByViewer, item.authorFollowedByViewer]), [[false, false]]);
    assert.equal(statement(/AS posted_by_viewer/), undefined);
  });

  it("asks nothing about follows when a signed-in viewer's feed is empty", async () => {
    script({ feedRows: [] });
    assert.equal((await call("GET", "/v1/feed?limit=2", await tokenFor(VIEWER))).status, 200);
    assert.equal(statement(/AS posted_by_viewer/), undefined);
  });

  it("asks the same of the map", async () => {
    script({ feedRows: [feedRow(VIDEO)], relationRows: [{ video_id: VIDEO, posted_by_viewer: false, author_followed: true }] });
    const items = ((await (await call("GET", "/v1/map/clips?limit=2", await tokenFor(VIEWER))).json()) as { items: Record<string, unknown>[] }).items;
    assert.deepEqual(items.map(item => item.authorFollowedByViewer), [true]);
  });
});

describe("author relations", () => {
  beforeEach(() => resetFakeNeon());

  it("leave a clip without an owner unfollowable, so the app offers no \"+\" for it", async () => {
    respondWith(() => [{ video_id: VIDEO, posted_by_viewer: null, author_followed: null }]);
    const relations = await authorRelations("postgres://fake.invalid/test", VIEWER, [VIDEO]);
    assert.deepEqual(relations.get(VIDEO), { postedByViewer: false, authorFollowedByViewer: null });
    assert.match(folded(queries[0].text), /COALESCE\(v\.owner_user_id = \?::uuid, false\) AS posted_by_viewer/);
    assert.match(folded(queries[0].text), /CASE WHEN v\.owner_user_id IS NULL THEN NULL ELSE EXISTS/);
    assert.match(folded(queries[0].text), /f\.follower_user_id = \?::uuid AND f\.followed_user_id = v\.owner_user_id\) END AS author_followed/);
  });

  it("send that null on in the feed", async () => {
    script({ feedRows: [feedRow(VIDEO)], relationRows: [{ video_id: VIDEO, posted_by_viewer: false, author_followed: null }] });
    const items = ((await (await call("GET", "/v1/feed?limit=2", await tokenFor(VIEWER))).json()) as { items: Record<string, unknown>[] }).items;
    assert.deepEqual(items.map(item => [item.postedByViewer, item.authorFollowedByViewer]), [[false, null]]);
  });

  it("start a new upload as the uploader's own", async () => {
    respondWith(() => [{
      id: VIDEO, stream_url: "https://media.test/clip.mp4", latitude: 1, longitude: 2,
      author_name: "@viewer", avatar_url: null, caption: "", audio_assessment: null,
    }]);
    const item = await insertFeedVideo("postgres://fake.invalid/test", "https://media.test/clip.mp4", 1, 2, VIEWER);
    assert.deepEqual([item.postedByViewer, item.authorFollowedByViewer], [true, false]);
  });
});
