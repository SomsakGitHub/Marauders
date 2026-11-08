import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { SignJWT } from "jose";

import worker from "../src/index";
import { decodeFollowListCursor, encodeFollowListCursor } from "../src/routes/followLists";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const JWT_SECRET = "follow-lists-test-signing-secret-0123456789abcd";
const VIEWER = "11111111-1111-4111-8111-111111111111";
const ALICE = "22222222-2222-4222-8222-222222222222";

const env = { DATABASE_URL: "postgres://fake.invalid/test", JWT_SIGNING_SECRET: JWT_SECRET } as never;

// Follow times as the Worker reads them back (to_char, microseconds kept), newest first.
const T1 = "2026-11-01T10:34:30.003123Z";
const T2 = "2026-11-01T10:30:00.000000Z";
const T3 = "2026-10-31T23:59:59.999999Z";

async function tokenFor(userId: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(JWT_SECRET));
}

async function call(path: string, token: string | null = null): Promise<Response> {
  const headers: Record<string, string> = token ? { Authorization: `Bearer ${token}` } : {};
  return worker.fetch(new Request(`https://api.test${path}`, { method: "GET", headers }), env);
}

const folded = (text: string) => text.replace(/\s+/g, " ");

function statement(pattern: RegExp) {
  return queries.find((query) => pattern.test(query.text));
}

function databaseError(code: string): Error {
  return Object.assign(new Error(`database failure ${code} secret-detail`), { code });
}

const b64url = (text: string) => Buffer.from(text).toString("base64url");

function pageRow(handle: string, followed_at = T1, overrides: Record<string, unknown> = {}) {
  return { handle, avatar_url: null, followed_at, followed_by_viewer: false, is_viewer: false, ...overrides };
}

type Script = { ownerRows?: unknown[]; pageRows?: unknown[]; rateCount?: number; failWith?: Error };

/** Answers each statement the routes run, told apart by their SQL text. */
function script(s: Script = {}): void {
  respondWith((query) => {
    if (/rate_limit_counters/.test(query.text)) return [{ count: s.rateCount ?? 1 }];
    if (/FROM user_follows f\b/.test(query.text)) {
      if (s.failWith) throw s.failWith;
      return s.pageRows ?? [];
    }
    if (folded(query.text).trim() === "SELECT id FROM app_users WHERE handle = ?") return s.ownerRows ?? [{ id: ALICE }];
    throw new Error(`unexpected statement: ${query.text}`);
  });
}

type ListBody = { items: Record<string, unknown>[]; nextCursor: string | null };

describe("GET /v1/users/:handle/followers and /following", () => {
  beforeEach(() => resetFakeNeon());

  it("answers a page of followers, newest first, in the shape the app reads", async () => {
    script({ pageRows: [pageRow("@bob", T1), pageRow("@carol", T2), pageRow("@dave", T3)] });
    const res = await call("/v1/users/@alice/followers?limit=2", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "private, no-store");
    assert.equal(res.headers.get("x-content-type-options"), "nosniff");
    const body = (await res.json()) as ListBody;
    assert.equal(body.items.length, 2);
    assert.deepEqual(body.items[0], { handle: "@bob", avatarURL: null, followedByViewer: false, isViewer: false });
    // The API names no account id anywhere.
    assert.deepEqual(Object.keys(body.items[0]).sort(), ["avatarURL", "followedByViewer", "handle", "isViewer"]);
    assert.equal(body.nextCursor, encodeFollowListCursor({ followedAt: T2, handle: "@carol" }));
    const page = statement(/FROM user_follows f\b/);
    assert.ok(page, "a page is read");
    assert.match(folded(page.text), /JOIN app_users u ON u\.id = f\.follower_user_id WHERE f\.followed_user_id = \?::uuid/);
    assert.match(folded(page.text), /ORDER BY f\.created_at DESC, f\.follower_user_id ASC LIMIT \?/);
    // The viewer twice (follow state, own row), then the profile's owner, then four NULLs for "no cursor", then limit + 1.
    assert.deepEqual(page.values, [VIEWER, VIEWER, ALICE, null, null, null, null, 3]);
  });

  it("reads the accounts a profile follows for /following", async () => {
    script({ pageRows: [pageRow("@bob")] });
    const res = await call("/v1/users/@alice/following", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    const page = statement(/FROM user_follows f\b/);
    assert.ok(page, "a page is read");
    assert.match(folded(page.text), /JOIN app_users u ON u\.id = f\.followed_user_id WHERE f\.follower_user_id = \?::uuid/);
    assert.match(folded(page.text), /ORDER BY f\.created_at DESC, f\.followed_user_id ASC LIMIT \?/);
    assert.match(folded(page.text), /f\.followed_user_id > COALESCE\(/);
    assert.equal(page.values[2], ALICE, "the profile's owner is bound where the list is read, not the viewer");
  });

  it("defaults to 20 rows and reads one more than it returns", async () => {
    const rows = Array.from({ length: 21 }, (_, i) => pageRow(`@user${i}`, T1));
    script({ pageRows: rows });
    const res = await call("/v1/users/@alice/followers", await tokenFor(VIEWER));
    const body = (await res.json()) as ListBody;
    assert.equal(body.items.length, 20);
    assert.equal(body.nextCursor, encodeFollowListCursor({ followedAt: T1, handle: "@user19" }));
    assert.equal(statement(/FROM user_follows f\b/)?.values.at(-1), 21);
  });

  it("has no nextCursor when no further row exists", async () => {
    script({ pageRows: [pageRow("@bob", T1), pageRow("@carol", T2)] });
    const token = await tokenFor(VIEWER);
    const full = (await (await call("/v1/users/@alice/followers?limit=2", token)).json()) as ListBody;
    assert.equal(full.items.length, 2);
    assert.equal(full.nextCursor, null);

    script({ pageRows: [] });
    const empty = (await (await call("/v1/users/@alice/followers?limit=2", token)).json()) as ListBody;
    assert.deepEqual(empty, { items: [], nextCursor: null });
  });

  it("continues after a cursor with the exact timestamp text and the handle it names", async () => {
    script({ pageRows: [pageRow("@dave", T3)] });
    const cursor = encodeFollowListCursor({ followedAt: T2, handle: "@carol" });
    const res = await call(`/v1/users/@alice/followers?limit=2&cursor=${cursor}`, await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    const page = statement(/FROM user_follows f\b/);
    assert.ok(page, "a page is read");
    assert.equal(page.values.filter((value) => value === T2).length, 3);
    assert.ok(page.values.includes("@carol"));
    assert.match(
      folded(page.text),
      /f\.created_at < \?::timestamptz OR \(f\.created_at = \?::timestamptz AND f\.follower_user_id > COALESCE\(\s*\(SELECT id FROM app_users WHERE handle = \?\),\s*'00000000-0000-0000-0000-000000000000'::uuid\)\)/,
    );
  });

  it("marks the viewer's own row and the accounts the viewer follows", async () => {
    script({
      pageRows: [
        pageRow("@viewer_self", T1, { is_viewer: true }),
        pageRow("@bob", T2, { followed_by_viewer: true, avatar_url: "https://media.test/avatars/bob.jpg" }),
        pageRow("@eve", T3),
      ],
    });
    const res = await call("/v1/users/@alice/followers", await tokenFor(VIEWER));
    const { items } = (await res.json()) as ListBody;
    assert.deepEqual(items[0], { handle: "@viewer_self", avatarURL: null, followedByViewer: false, isViewer: true });
    assert.deepEqual(items[1], { handle: "@bob", avatarURL: "https://media.test/avatars/bob.jpg", followedByViewer: true, isViewer: false });
    assert.deepEqual(items[2], { handle: "@eve", avatarURL: null, followedByViewer: false, isViewer: false });
  });

  it("is reached before the profile catch-all", async () => {
    const token = await tokenFor(VIEWER);
    for (const path of ["/v1/users/@alice/followers", "/v1/users/@alice/following"]) {
      resetFakeNeon();
      script({ pageRows: [pageRow("@bob")] });
      const res = await call(path, token);
      assert.equal(res.status, 200, path);
      assert.ok(Array.isArray(((await res.json()) as ListBody).items), path);
      assert.equal(statement(/AS follower_count/), undefined, `${path} must not run the profile query`);
    }
  });

  it("needs a signed-in viewer", async () => {
    script();
    for (const path of ["/v1/users/@alice/followers", "/v1/users/@alice/following"]) {
      for (const token of [null, "not-a-token"]) {
        const res = await call(path, token);
        assert.equal(res.status, 401, `${path} ${token}`);
        assert.deepEqual(await res.json(), { error: "authentication required" });
      }
    }
    assert.equal(queries.length, 0, "no statement runs for a guest");
  });

  it("limits each viewer to 60 requests a minute", async () => {
    script({ rateCount: 61 });
    const res = await call("/v1/users/@alice/followers", await tokenFor(VIEWER));
    assert.equal(res.status, 429);
    assert.ok(res.headers.get("retry-after"), "a limited answer says when to come back");
    assert.equal(statement(/user_follows/), undefined, "nothing is read for a limited viewer");
    assert.equal(statement(/rate_limit_counters/)?.values[0], `follow-list:${VIEWER}`);
  });

  it("answers 503 when the database is not configured", async () => {
    script();
    const headers = { Authorization: `Bearer ${await tokenFor(VIEWER)}` };
    const res = await worker.fetch(
      new Request("https://api.test/v1/users/@alice/followers", { method: "GET", headers }),
      { JWT_SIGNING_SECRET: JWT_SECRET } as never,
    );
    assert.equal(res.status, 503);
    assert.deepEqual(await res.json(), { error: "service configuration incomplete" });
    assert.equal(queries.length, 0, "nothing is read without a database");
  });

  it("answers 404 for an unknown handle without reading a page", async () => {
    script({ ownerRows: [] });
    const res = await call("/v1/users/@nobody/followers", await tokenFor(VIEWER));
    assert.equal(res.status, 404);
    assert.deepEqual(await res.json(), { error: "profile not found" });
    assert.equal(statement(/FROM user_follows f\b/), undefined);
    const lookup = queries.find((query) => folded(query.text).trim() === "SELECT id FROM app_users WHERE handle = ?");
    assert.deepEqual(lookup?.values, ["@nobody"]);
  });

  it("finds the account by its handle whatever the case, with or without the @", async () => {
    const token = await tokenFor(VIEWER);
    for (const handle of ["%40Alice", "ALICE", "@alice"]) {
      resetFakeNeon();
      script();
      const res = await call(`/v1/users/${handle}/followers`, token);
      assert.equal(res.status, 200, handle);
      const lookup = queries.find((query) => folded(query.text).trim() === "SELECT id FROM app_users WHERE handle = ?");
      assert.deepEqual(lookup?.values, ["@alice"], handle);
    }
  });

  it("refuses a bad handle, limit or cursor with 400 before touching the data", async () => {
    const token = await tokenFor(VIEWER);
    const paths = [
      ...["%20", "me", "bad%2Fhandle", "%E0%A4%A"].map((handle) => `/v1/users/${handle}/followers`),
      ...["0", "51", "abc", "-1", "1.5"].map((limit) => `/v1/users/@alice/following?limit=${limit}`),
      ...[
        "!!!",
        "A".repeat(201),
        b64url("hello"),
        b64url("2026-02-30T10:00:00.000000Z|@alice"),
        b64url("2026-11-01T10:34:30.003Z|@alice"),
        b64url(`${T1}|not a handle`),
        b64url(`${T1}|@me`),
      ].map((cursor) => `/v1/users/@alice/followers?cursor=${cursor}`),
    ];
    for (const path of paths) {
      resetFakeNeon();
      script();
      const res = await call(path, token);
      assert.equal(res.status, 400, path);
      assert.equal(statement(/user_follows/), undefined, `${path} must not read a page`);
      assert.equal(statement(/FROM app_users/), undefined, `${path} must not look the account up`);
    }
  });

  it("answers 500 without leaking the database message, and logs the SQLSTATE", async (t) => {
    const log = t.mock.method(console, "error", () => {});
    script({ failWith: databaseError("57014") });
    const res = await call("/v1/users/@alice/followers", await tokenFor(VIEWER));
    assert.equal(res.status, 500);
    const text = await res.text();
    assert.deepEqual(JSON.parse(text), { error: "failed to load list" });
    assert.doesNotMatch(text, /secret-detail/);
    assert.ok(log.mock.calls.some((call) => call.arguments.some((arg) => String(arg).includes("57014"))), "the SQLSTATE is logged");
  });

  it("round-trips a cursor and reads the documented example", () => {
    const cursor = { followedAt: T1, handle: "@alice" };
    assert.equal(encodeFollowListCursor(cursor), "MjAyNi0xMS0wMVQxMDozNDozMC4wMDMxMjNafEBhbGljZQ");
    assert.deepEqual(decodeFollowListCursor("MjAyNi0xMS0wMVQxMDozNDozMC4wMDMxMjNafEBhbGljZQ"), cursor);
    assert.equal(decodeFollowListCursor(null), null);
    assert.equal(decodeFollowListCursor(""), null);
    assert.throws(() => decodeFollowListCursor("!!!"), /invalid cursor/);
  });
});
