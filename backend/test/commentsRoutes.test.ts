import assert from "node:assert/strict";
import { beforeEach, describe, it, mock } from "node:test";

import { SignJWT } from "jose";

import worker from "../src/index";
import { COMMENT_REQUEST_MAX_BYTES } from "../src/routes/comments";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const JWT_SECRET = "comments-test-signing-secret-0123456789abcdef";
const VIEWER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const CLIP_OWNER = "33333333-3333-4333-8333-333333333333";
const VIDEO = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const COMMENT_A = "c0000000-0000-4000-8000-00000000000a";
const COMMENT_B = "c0000000-0000-4000-8000-00000000000b";
const COMMENT_C = "c0000000-0000-4000-8000-00000000000c";
/** The request cap the README documents, written out so that changing the constant in the Worker fails a test. */
const SIXTEEN_KIB = 16 * 1024;

const env ={ DATABASE_URL: "postgres://fake.invalid/test", JWT_SIGNING_SECRET: JWT_SECRET } as never;

async function tokenFor(userId: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(JWT_SECRET));
}

type Call = { token?: string | null; authorization?: string; body?: BodyInit; headers?: Record<string, string>; env?: never };

function call(method: string, path: string, options: Call = {}): Promise<Response> {
  const headers: Record<string, string> = { ...options.headers };
  if (options.authorization) headers.Authorization = options.authorization;
  else if (options.token) headers.Authorization = `Bearer ${options.token}`;
  // A streamed body has to say so; Node would otherwise refuse to build the request.
  const init = { method, headers, body: options.body, duplex: "half" } as RequestInit;
  return worker.fetch(new Request(`https://api.test${path}`, init), options.env ?? env);
}

/** A request body that arrives in the given pieces, the way a slow connection delivers it. */
function chunked(...pieces: Uint8Array[]): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      for (const piece of pieces) controller.enqueue(piece);
      controller.close();
    },
  });
}

async function postComment(payload: unknown, options: Call & { video?: string } = {}): Promise<Response> {
  const token = options.token === undefined ? await tokenFor(VIEWER) : options.token;
  const body = typeof payload === "string" ? payload : JSON.stringify(payload);
  return call("POST", `/v1/videos/${options.video ?? VIDEO}/comments`, { ...options, token, body });
}

function row(overrides: Record<string, unknown> = {}) {
  return {
    id: COMMENT_A,
    body: "Great spot",
    language: null,
    created_at: "2026-10-30T10:00:00.123Z",
    author_user_id: OTHER,
    handle: "alice",
    avatar_url: null,
    clip_owner_id: CLIP_OWNER,
    ...overrides,
  };
}

type Script = {
  videoExists?: boolean;
  listRows?: unknown[];
  insertRows?: unknown[];
  insertError?: Error;
  deleteRows?: unknown[];
  failEverything?: Error;
  rateCount?: number;
};

/** Answers each statement the routes run, told apart by their SQL text. */
function script(s: Script = {}): void {
  respondWith((query) => {
    if (s.failEverything) throw s.failEverything;
    if (/rate_limit_counters/.test(query.text)) return [{ count: s.rateCount ?? 1 }];
    if (/SELECT 1 FROM feed_videos/.test(query.text)) return s.videoExists === false ? [] : [{ "?column?": 1 }];
    if (/INSERT INTO comments/.test(query.text)) {
      if (s.insertError) throw s.insertError;
      return s.insertRows ?? [];
    }
    if (/DELETE FROM comments/.test(query.text)) return s.deleteRows ?? [];
    if (/FROM comments c/.test(query.text)) return s.listRows ?? [];
    throw new Error(`unexpected statement: ${query.text}`);
  });
}

function statement(pattern: RegExp) {
  return queries.find((query) => pattern.test(query.text));
}

/** The text of the first statement matching `pattern`, runs of whitespace folded so re-wrapping the SQL breaks nothing. */
function sqlOf(pattern: RegExp): string {
  return (statement(pattern)?.text ?? "").replace(/\s+/g, " ");
}

function databaseError(code: string, constraint?: string): Error {
  return Object.assign(new Error(`database failure ${code} secret-detail`), { code, constraint });
}

type JSONBody = Record<string, unknown>;

/** The `canDelete` the comments of the clip carry for `userId`, or for a guest when it is null. */
async function canDeleteAs(userId: string | null): Promise<unknown[]> {
  const res = await call("GET", `/v1/videos/${VIDEO}/comments`, { token: userId && await tokenFor(userId) });
  return ((await res.json()) as { items: JSONBody[] }).items.map((item) => item.canDelete);
}

describe("GET /v1/videos/:id/comments", () => {
  beforeEach(() => resetFakeNeon());

  it("lists a clip's comments, newest first, for a guest", async () => {
    script({ listRows: [row()] });
    const res = await call("GET", `/v1/videos/${VIDEO}/comments`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.equal(res.headers.get("x-content-type-options"), "nosniff");
    assert.deepEqual(await res.json(), {
      items: [{
        id: COMMENT_A, body: "Great spot", language: null, createdAt: "2026-10-30T10:00:00.123Z",
        authorName: "alice", authorAvatarURL: null, canDelete: false,
      }],
      nextCursor: null,
    });
    assert.deepEqual(statement(/FROM comments c/)?.values, [VIDEO, null, null, VIDEO, 31]);
    assert.match(sqlOf(/FROM comments c/), /ORDER BY c\.created_at DESC, c\.id DESC/);
  });

  it("returns the id of the last comment as the cursor when more rows exist", async () => {
    script({ listRows: [row({ id: COMMENT_A }), row({ id: COMMENT_B }), row({ id: COMMENT_C })] });
    const res = await call("GET", `/v1/videos/${VIDEO}/comments?limit=2`);
    const json = await res.json() as { items: { id: string }[]; nextCursor: string | null };
    assert.deepEqual(json.items.map((item) => item.id), [COMMENT_A, COMMENT_B]);
    assert.equal(json.nextCursor, COMMENT_B);
  });

  it("has no next page when the clip holds exactly as many comments as were asked for", async () => {
    script({ listRows: [row({ id: COMMENT_A }), row({ id: COMMENT_B })] });
    const res = await call("GET", `/v1/videos/${VIDEO}/comments?limit=2`);
    const json = await res.json() as { items: { id: string }[]; nextCursor: string | null };
    assert.deepEqual(json.items.map((item) => item.id), [COMMENT_A, COMMENT_B]);
    assert.equal(json.nextCursor, null);
  });

  it("passes the cursor to the query", async () => {
    script({ listRows: [] });
    const res = await call("GET", `/v1/videos/${VIDEO}/comments?limit=2&cursor=${COMMENT_B}`);
    assert.equal(res.status, 200);
    assert.deepEqual(statement(/FROM comments c/)?.values, [VIDEO, COMMENT_B, COMMENT_B, VIDEO, 3]);
    // Older than the cursor: a `>` here would page forward into the comments already shown.
    assert.match(sqlOf(/FROM comments c/), /\(c\.created_at, c\.id\) < \(/);
  });

  it("reads an empty limit and an empty cursor as not given", async () => {
    script({ listRows: [] });
    const res = await call("GET", `/v1/videos/${VIDEO}/comments?limit=&cursor=`);
    assert.equal(res.status, 200);
    assert.deepEqual(statement(/FROM comments c/)?.values, [VIDEO, null, null, VIDEO, 31]);
  });

  it("accepts any page size from 1 to 50 and asks the database for one row more", async () => {
    script({ listRows: [] });
    const sizes = [1, 2, 30, 49, 50];
    for (const limit of sizes) {
      const res = await call("GET", `/v1/videos/${VIDEO}/comments?limit=${limit}`);
      assert.equal(res.status, 200, `limit=${limit}`);
    }
    // The extra row is how the route knows whether another page exists.
    const asked = queries.filter((query) => /FROM comments c/.test(query.text)).map((query) => query.values[4]);
    assert.deepEqual(asked, sizes.map((limit) => limit + 1));
  });

  it("lets the author and the clip owner delete, and nobody else", async () => {
    script({ listRows: [
      row({ id: COMMENT_A, author_user_id: VIEWER }),
      row({ id: COMMENT_B, author_user_id: OTHER, clip_owner_id: CLIP_OWNER }),
    ] });
    assert.deepEqual(await canDeleteAs(VIEWER), [true, false], "an author deletes only their own comment");
    assert.deepEqual(await canDeleteAs(OTHER), [false, true]);
    assert.deepEqual(await canDeleteAs(CLIP_OWNER), [true, true], "the owner of the clip deletes any comment on it");
    assert.deepEqual(await canDeleteAs("44444444-4444-4444-8444-444444444444"), [false, false]);
    assert.deepEqual(await canDeleteAs(null), [false, false]);
  });

  it("lets only the author delete on a clip that has no owner", async () => {
    // feed_videos.owner_user_id is nullable (migration 006), and a missing owner is nobody, not whoever is asking.
    script({ listRows: [row({ author_user_id: OTHER, clip_owner_id: null })] });
    assert.deepEqual(await canDeleteAs(OTHER), [true]);
    assert.deepEqual(await canDeleteAs(VIEWER), [false]);
    assert.deepEqual(await canDeleteAs(null), [false]);
  });

  it("404s for a clip that does not exist", async () => {
    script({ videoExists: false });
    const res = await call("GET", `/v1/videos/${VIDEO}/comments`);
    assert.equal(res.status, 404);
  });

  it("rejects a session it cannot verify instead of treating the viewer as a guest", async () => {
    script();
    const res = await call("GET", `/v1/videos/${VIDEO}/comments`, { authorization: "Bearer not-a-valid-token-at-all-0000" });
    assert.equal(res.status, 401);
    assert.equal(queries.length, 0);
  });

  it("validates the clip id, limit and cursor before it touches the database", async () => {
    script();
    for (const path of [
      "/v1/videos/not-a-uuid/comments",
      `/v1/videos/${VIDEO}/comments?limit=0`,
      `/v1/videos/${VIDEO}/comments?limit=51`,
      `/v1/videos/${VIDEO}/comments?limit=abc`,
      `/v1/videos/${VIDEO}/comments?limit=-1`,
      `/v1/videos/${VIDEO}/comments?cursor=not-a-uuid`,
    ]) {
      const res = await call("GET", path);
      assert.equal(res.status, 400, path);
    }
    assert.equal(queries.length, 0);
  });

  it("answers 503 when the database is not configured", async () => {
    const res = await call("GET", `/v1/videos/${VIDEO}/comments`, { env: { JWT_SIGNING_SECRET: JWT_SECRET } as never });
    assert.equal(res.status, 503);
  });

  it("hides database failures behind a generic 500 and logs what failed", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    script({ failEverything: databaseError("57014") });
    const res = await call("GET", `/v1/videos/${VIDEO}/comments`);
    assert.equal(res.status, 500);
    const text = await res.text();
    assert.ok(!text.includes("secret-detail"));
    assert.deepEqual(logged.mock.calls.map((entry) => entry.arguments), [
      ["comments list failed", "57014", "database failure 57014 secret-detail"],
    ]);
  });
});

describe("POST /v1/videos/:id/comments", () => {
  beforeEach(() => resetFakeNeon());

  it("requires a session", async () => {
    script();
    const res = await postComment({ body: "hi" }, { token: null });
    assert.equal(res.status, 401);
    assert.equal(queries.length, 0);
  });

  it("stores the trimmed text with its language and returns the comment", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER, body: "Nice place", language: "th" })] });
    const res = await postComment({ body: "  Nice place \n", language: "th-TH" }, { video: VIDEO.toUpperCase() });
    assert.equal(res.status, 201);
    const json = await res.json() as { comment: JSONBody };
    assert.equal(json.comment.body, "Nice place");
    assert.equal(json.comment.language, "th");
    assert.equal(json.comment.canDelete, true);
    assert.deepEqual(statement(/INSERT INTO comments/)?.values, [VIEWER, "Nice place", "th", VIDEO]);
  });

  it("stores no language when the client sends none or an unsupported one", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    await postComment({ body: "hello" });
    await postComment({ body: "hello", language: "xx" });
    const inserts = queries.filter((query) => /INSERT INTO comments/.test(query.text));
    assert.deepEqual(inserts.map((query) => query.values[2]), [null, null]);
  });

  it("accepts text up to the limit, counted in characters rather than UTF-16 units", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    assert.equal((await postComment({ body: "a".repeat(500) })).status, 201);
    assert.equal((await postComment({ body: "😀".repeat(500) })).status, 201);
    assert.equal((await postComment({ body: "👨‍👩‍👧‍👦 สวัสดีครับ" })).status, 201);
  });

  it("422s for text that is empty, too long or not text, without writing anything", async () => {
    script({ insertRows: [row()] });
    for (const body of ["", "   \n\t ", 42, null, ["x"], { a: 1 }, "a".repeat(501), "😀".repeat(501)]) {
      const res = await postComment({ body });
      assert.equal(res.status, 422, JSON.stringify(body)?.slice(0, 20));
    }
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("422s for text made only of characters nobody can see", async () => {
    script({ insertRows: [row()] });
    for (const body of [
      "\u200b", "\u200b\u200b\u200b", "\u200c\u200d", "\u200e\u200f", "\u2060", "\ufeff", "\u00ad", "\u2800", "\u3164",
      "\u115f\u1160", "\uffa0", " \u200b \u00a0 \n", "\u2028\u2029", "\ufe0f", "\ufe00\ufe0e", "\u034f", "\ufffc",
      "\u0000\u0007", "\u0085",
      "\u200b \u200b", "\u200b\u00a0\u200b", "\u200b\u2028\u200b", "\u0080", "\u009b\u200b",
    ]) {
      const res = await postComment({ body });
      assert.equal(res.status, 422, JSON.stringify(body));
    }
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("keeps invisible characters that sit inside real text", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    const text = "ไม่\u200cได้ 👍🏽";
    assert.equal((await postComment({ body: text })).status, 201);
    assert.equal(statement(/INSERT INTO comments/)?.values[1], text);
  });

  it("stores text without C1 control characters", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    assert.equal((await postComment({ body: "a\u009bb\u0080c" })).status, 201);
    assert.equal(statement(/INSERT INTO comments/)?.values[1], "abc");
  });

  it("stores at most ten line breaks and turns the rest into spaces", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    assert.equal((await postComment({ body: "x" + "\n".repeat(300) + "y" })).status, 201);
    assert.equal(statement(/INSERT INTO comments/)?.values[1], "x" + "\n".repeat(10) + " ".repeat(290) + "y");
  });

  it("accepts text that draws something, whatever script it is in", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    for (const body of ["😀", "สวัสดีครับ", "ก้", "้", "مرحبا", "…", "x"]) {
      assert.equal((await postComment({ body })).status, 201, JSON.stringify(body));
    }
  });

  it("422s for an unpaired surrogate instead of failing in the database", async () => {
    script({ insertRows: [row()] });
    for (const raw of ['{"body":"\\ud800"}', '{"body":"ok \\udc00"}', '{"body":"\\ud83d no pair"}']) {
      const res = await postComment(raw);
      assert.equal(res.status, 422, raw);
    }
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("400s for a body that is not a JSON object", async () => {
    script({ insertRows: [row()] });
    for (const raw of ["{", "", "null", "42", '"text"']) {
      const res = await postComment(raw);
      assert.equal(res.status, 400, raw);
    }
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("413s when the request announces a body far larger than any comment", async () => {
    script({ insertRows: [row()] });
    const res = await postComment({ body: "hi" }, { headers: { "content-length": String(64 * 1024) } });
    assert.equal(res.status, 413);
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("413s when the streamed body turns out larger than any comment", async () => {
    script({ insertRows: [row()] });
    const res = await postComment(JSON.stringify({ body: "x", padding: "y".repeat(64 * 1024) }));
    assert.equal(res.status, 413);
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("413s when the pieces of a streamed body add up to more than any comment", async () => {
    script({ insertRows: [row()] });
    // Every piece is under the cap on its own; only their sum is over it.
    const piece = new TextEncoder().encode(" ".repeat(COMMENT_REQUEST_MAX_BYTES / 2));
    const stream = chunked(piece, piece, new TextEncoder().encode('{"body":"hi"}'));
    const res = await call("POST", `/v1/videos/${VIDEO}/comments`, { token: await tokenFor(VIEWER), body: stream });
    assert.equal(res.status, 413);
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("stops reading a streamed body once it is past the size limit", async () => {
    script({ insertRows: [row()] });
    const piece = new TextEncoder().encode(" ".repeat(1024));
    let pulls = 0;
    let cancelled = false;
    // Ten thousand pieces, ten megabytes in all; a reader that gives up at the cap pulls about seventeen of them.
    const huge = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (++pulls > 10_000) controller.close();
        else controller.enqueue(piece);
      },
      cancel() { cancelled = true; },
    });
    const res = await call("POST", `/v1/videos/${VIDEO}/comments`, { token: await tokenFor(VIEWER), body: huge });
    assert.equal(res.status, 413);
    assert.equal(cancelled, true, "the rest of the upload is told to stop");
    assert.ok(pulls <= COMMENT_REQUEST_MAX_BYTES / piece.byteLength + 3, `${pulls} pieces were pulled`);
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("accepts an announced length of exactly 16 KiB and refuses one byte more", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    // The body itself is small; only the length it announces sits at the edge.
    const announcing = (bytes: number) => ({ headers: { "content-length": String(bytes) } });
    assert.equal((await postComment({ body: "hi" }, announcing(SIXTEEN_KIB))).status, 201);
    assert.equal((await postComment({ body: "hi" }, announcing(SIXTEEN_KIB + 1))).status, 413);
  });

  it("accepts a body of exactly 16 KiB and refuses one byte more", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    const overhead = JSON.stringify({ body: "x", padding: "" }).length;
    const ofSize = (bytes: number) => JSON.stringify({ body: "x", padding: "y".repeat(bytes - overhead) });
    assert.equal(ofSize(SIXTEEN_KIB).length, SIXTEEN_KIB);
    assert.equal((await postComment(ofSize(SIXTEEN_KIB))).status, 201);
    assert.equal((await postComment(ofSize(SIXTEEN_KIB + 1))).status, 413);
  });

  it("keeps the request cap at 16 KiB, which the tests that build on the constant rely on", () => {
    assert.equal(COMMENT_REQUEST_MAX_BYTES, SIXTEEN_KIB);
  });

  it("drops a byte order mark in front of the body", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    assert.equal((await postComment("﻿" + JSON.stringify({ body: "hello" }))).status, 201);
    assert.equal(statement(/INSERT INTO comments/)?.values[1], "hello");
  });

  it("reads characters that arrive split across pieces of the body", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    const text = "สวัสดีครับ 😀";
    const bytes = new TextEncoder().encode(JSON.stringify({ body: text }));
    // Cut inside the first Thai letter (three bytes) and inside the emoji (four bytes) so each piece ends mid-character.
    const inThai = bytes.indexOf(0xe0) + 1;
    const inEmoji = bytes.length - 4;
    const stream = chunked(bytes.slice(0, inThai), bytes.slice(inThai, inEmoji), bytes.slice(inEmoji));
    const res = await call("POST", `/v1/videos/${VIDEO}/comments`, { token: await tokenFor(VIEWER), body: stream });
    assert.equal(res.status, 201);
    assert.equal(statement(/INSERT INTO comments/)?.values[1], text);
  });

  it("answers 400 when the connection breaks in the middle of the body", async () => {
    script({ insertRows: [row()] });
    let pulls = 0;
    const broken = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls += 1;
        if (pulls === 1) controller.enqueue(new TextEncoder().encode('{"body":"hel'));
        else controller.error(new Error("connection reset"));
      },
    });
    const res = await call("POST", `/v1/videos/${VIDEO}/comments`, { token: await tokenFor(VIEWER), body: broken });
    assert.equal(res.status, 400);
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("404s when the clip does not exist", async () => {
    script({ insertRows: [] });
    const res = await postComment({ body: "hello" });
    assert.equal(res.status, 404);
  });

  it("400s for a malformed clip id", async () => {
    script();
    const res = await postComment({ body: "hello" }, { video: "nope" });
    assert.equal(res.status, 400);
  });

  it("answers 429 with Retry-After once the viewer passes ten comments a minute", async () => {
    script({ rateCount: 11, insertRows: [row()] });
    const res = await postComment({ body: "hello" });
    assert.equal(res.status, 429);
    assert.ok(Number(res.headers.get("retry-after")) >= 1);
    assert.equal(statement(/INSERT INTO comments/), undefined);
  });

  it("counts each viewer's comments in one-minute windows and says when the window is over", async () => {
    // Not on a ten-minute boundary, so a window of the wrong length starts at a different time.
    mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-30T10:07:20.000Z") });
    try {
      script({ rateCount: 10, insertRows: [row({ author_user_id: VIEWER })] });
      assert.equal((await postComment({ body: "the tenth this minute" })).status, 201);
      const counter = statement(/rate_limit_counters/);
      assert.equal(counter?.values[0], `comment:${VIEWER}`);
      assert.equal(counter?.values[1], "2026-10-30T10:07:00.000Z");

      resetFakeNeon();
      script({ rateCount: 11, insertRows: [row({ author_user_id: VIEWER })] });
      const res = await postComment({ body: "the eleventh" });
      assert.equal(res.status, 429);
      assert.equal(res.headers.get("retry-after"), "40");
      assert.equal(statement(/INSERT INTO comments/), undefined);
    } finally {
      mock.timers.reset();
    }
  });

  it("asks the viewer to sign in again when their account row is gone", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    script({ insertError: databaseError("23503", "comments_author_user_id_fkey") });
    const res = await postComment({ body: "hello" });
    assert.equal(res.status, 401);
    assert.ok(!(await res.text()).includes("secret-detail"));
    assert.equal(logged.mock.callCount(), 0, "an account that is gone is an expected answer, not a failure");
  });

  it("404s when the clip disappears between the check and the insert", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    script({ insertError: databaseError("23503", "comments_video_id_fkey") });
    const res = await postComment({ body: "hello" });
    assert.equal(res.status, 404);
    assert.equal(logged.mock.callCount(), 0);
  });

  it("hides other database failures behind a generic 500 and logs what failed, but not the comment", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    script({ insertError: databaseError("57014") });
    const res = await postComment({ body: "a private remark" });
    assert.equal(res.status, 500);
    assert.ok(!(await res.text()).includes("secret-detail"));
    const calls = logged.mock.calls.map((entry) => entry.arguments);
    assert.deepEqual(calls, [["comments create failed", "57014", "database failure 57014 secret-detail"]]);
    assert.ok(!JSON.stringify(calls).includes("a private remark"));
  });
});

describe("DELETE /v1/videos/:id/comments/:commentId", () => {
  beforeEach(() => resetFakeNeon());

  it("requires a session", async () => {
    script();
    const res = await call("DELETE", `/v1/videos/${VIDEO}/comments/${COMMENT_A}`);
    assert.equal(res.status, 401);
    assert.equal(queries.length, 0);
  });

  it("deletes through one statement that only matches the author or the clip owner", async () => {
    script({ deleteRows: [{ id: COMMENT_A }] });
    const res = await call("DELETE", `/v1/videos/${VIDEO}/comments/${COMMENT_A.toUpperCase()}`, { token: await tokenFor(VIEWER) });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: "deleted" });
    const query = statement(/DELETE FROM comments/);
    assert.deepEqual(query?.values, [COMMENT_A, VIDEO, VIEWER, VIEWER]);
    assert.match(query?.text ?? "", /c\.author_user_id = \?::uuid OR v\.owner_user_id = \?::uuid/);
    const folded = sqlOf(/DELETE FROM comments/);
    // Without this join the clip table is crossed with every comment, and owning any clip would allow deleting any comment.
    assert.match(folded, /\bv\.id = c\.video_id\b|\bc\.video_id = v\.id\b/);
    // The author-or-owner test is one parenthesised condition; outside the parentheses the OR would swallow the rest.
    assert.match(folded, /AND \(c\.author_user_id = \?::uuid OR v\.owner_user_id = \?::uuid\)/);
  });

  it("404s when nothing matched, whether the comment is missing or belongs to someone else", async () => {
    script({ deleteRows: [] });
    const res = await call("DELETE", `/v1/videos/${VIDEO}/comments/${COMMENT_A}`, { token: await tokenFor(OTHER) });
    assert.equal(res.status, 404);
  });

  it("400s for malformed ids", async () => {
    script();
    const token = await tokenFor(VIEWER);
    assert.equal((await call("DELETE", `/v1/videos/nope/comments/${COMMENT_A}`, { token })).status, 400);
    assert.equal((await call("DELETE", `/v1/videos/${VIDEO}/comments/nope`, { token })).status, 400);
    assert.equal(queries.length, 0);
  });

  it("hides database failures behind a generic 500 and logs what failed", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    script({ failEverything: databaseError("57014") });
    const res = await call("DELETE", `/v1/videos/${VIDEO}/comments/${COMMENT_A}`, { token: await tokenFor(VIEWER) });
    assert.equal(res.status, 500);
    assert.ok(!(await res.text()).includes("secret-detail"));
    assert.deepEqual(logged.mock.calls.map((entry) => entry.arguments), [
      ["comments delete failed", "57014", "database failure 57014 secret-detail"],
    ]);
  });
});

// Only a hand-written fake has ever answered these statements, so nothing but their text says what they ask of the
// database. Each is pinned whole, whitespace folded: an edit to a join, a column or a filter changes it, and whoever
// makes the edit has to change the expectation too, which is the moment to run the new statement on a real Postgres.
describe("the statements the comments routes run", () => {
  beforeEach(() => resetFakeNeon());

  const commentColumns = "u.handle, u.avatar_url, v.owner_user_id AS clip_owner_id";

  it("list a clip's comments newest first, each with its author and the clip's owner", async () => {
    script({ listRows: [] });
    await call("GET", `/v1/videos/${VIDEO}/comments`);
    assert.equal(sqlOf(/SELECT 1 FROM feed_videos/), "SELECT 1 FROM feed_videos WHERE id = ?::uuid LIMIT 1");
    assert.equal(sqlOf(/FROM comments c/).trim(), [
      `SELECT c.id, c.body, c.language, c.created_at, c.author_user_id, ${commentColumns}`,
      "FROM comments c",
      "JOIN app_users u ON u.id = c.author_user_id",
      "JOIN feed_videos v ON v.id = c.video_id",
      "WHERE c.video_id = ?::uuid",
      "AND (?::uuid IS NULL OR (c.created_at, c.id) < (",
      "SELECT created_at, id FROM comments WHERE id = ?::uuid AND video_id = ?::uuid))",
      "ORDER BY c.created_at DESC, c.id DESC",
      "LIMIT ?",
    ].join(" "));
  });

  it("insert a comment only on a clip that exists and return it with its author and the clip's owner", async () => {
    script({ insertRows: [row({ author_user_id: VIEWER })] });
    await postComment({ body: "hello" });
    assert.equal(sqlOf(/INSERT INTO comments/).trim(), [
      "WITH inserted AS (",
      "INSERT INTO comments (video_id, author_user_id, body, language)",
      "SELECT v.id, ?::uuid, ?, ? FROM feed_videos v WHERE v.id = ?::uuid",
      "RETURNING id, body, language, created_at, author_user_id, video_id)",
      `SELECT i.id, i.body, i.language, i.created_at, i.author_user_id, ${commentColumns}`,
      "FROM inserted i JOIN app_users u ON u.id = i.author_user_id JOIN feed_videos v ON v.id = i.video_id",
    ].join(" "));
  });

  it("delete one comment of the clip, for its author or the clip's owner, and say which one went", async () => {
    script({ deleteRows: [{ id: COMMENT_A }] });
    await call("DELETE", `/v1/videos/${VIDEO}/comments/${COMMENT_A}`, { token: await tokenFor(VIEWER) });
    assert.equal(sqlOf(/DELETE FROM comments/).trim(), [
      "DELETE FROM comments c USING feed_videos v",
      "WHERE c.id = ?::uuid AND c.video_id = ?::uuid AND v.id = c.video_id",
      "AND (c.author_user_id = ?::uuid OR v.owner_user_id = ?::uuid)",
      "RETURNING c.id",
    ].join(" "));
  });
});
