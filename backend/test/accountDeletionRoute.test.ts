import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import { signAccessToken } from "../src/auth/accessToken";
import worker from "../src/index";
import type { Env } from "../src/index";
import { FakeBucket } from "./fakes/bucket";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";
import type { Query } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const USER = "11111111-1111-4111-8111-111111111111";
const DATABASE_URL = "postgres://fake.invalid/test";
const JWT_SECRET = "route-test-signing-secret-0123456789abcdef";
const ORIGIN = "https://app.example.test";
const HOUR_MS = 3_600_000;

type Script = {
  /** What the rate-limit counter answers: the number of requests the person has made in the window, this one included. */
  rateCount?: number;
  /** The person's row; null for an account that is already gone. */
  appleSub?: string | null;
};

/** Answers each statement the route runs, told apart by their SQL text. */
function script({ rateCount = 1, appleSub = null }: Script = {}): void {
  resetFakeNeon();
  respondWith((query) => {
    if (/rate_limit_counters/.test(query.text)) return [{ count: rateCount }];
    // The deleting statement names both tables, so it is told apart before the reads.
    if (/WITH deleted_clips/.test(query.text)) return [];
    if (/FROM feed_videos/.test(query.text)) return [];
    if (/FROM app_users/.test(query.text)) {
      return appleSub === null ? [] : [{ id: USER, apple_sub: appleSub, avatar_url: null }];
    }
    throw new Error(`unexpected query: ${query.text}`);
  });
}

function environment(): Env {
  return {
    DATABASE_URL,
    JWT_SIGNING_SECRET: JWT_SECRET,
    ENVIRONMENT: "test",
    APPLE_CLIENT_ID: "com.example.test",
    VIDEOS: new FakeBucket(),
  } as unknown as Env;
}

/** Remembers what the Worker handed to waitUntil, as Cloudflare's context would run it. */
class RecordingContext {
  promises: Promise<unknown>[] = [];

  waitUntil(promise: Promise<unknown>): void {
    this.promises.push(promise);
  }

  passThroughOnException(): void {}
}

function requestFor(method: string, token: string | null, body: unknown = {}): Request {
  const headers: Record<string, string> = { "content-type": "application/json", Origin: ORIGIN };
  if (token !== null) {
    headers.Authorization = `Bearer ${token}`;
  }
  return new Request("https://api.test/v1/users/me", { method, headers, body: JSON.stringify(body) });
}

function statement(pattern: RegExp): Query | undefined {
  return queries.find((query) => pattern.test(query.text));
}

const realFetch = globalThis.fetch;
/** Every URL the Worker tried to reach outside itself; Apple's is the one these tests must never see. */
let outsideCalls: string[] = [];

beforeEach(() => {
  outsideCalls = [];
  globalThis.fetch = (async (input: string | URL | Request) => {
    outsideCalls.push(String(input));
    throw new TypeError("no call may leave the Worker in these tests");
  }) as typeof fetch;
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("DELETE /v1/users/me through the router: who may ask", () => {
  it("answers 401 without an Authorization header, and nothing else happens", async () => {
    script();
    const context = new RecordingContext();

    const response = await worker.fetch(requestFor("DELETE", null), environment(), context as unknown as ExecutionContext);

    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { error: "authentication required" });
    assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN, "the answer goes through withCors");
    assert.deepEqual(queries, [], "not even the rate limit counter was touched");
    assert.deepEqual(outsideCalls, []);
    assert.equal(context.promises.length, 0);
  });

  const notOurs: Array<[string, () => Promise<string>]> = [
    ["a Bearer that is not a token", async () => "this-is-not-a-token-0123456789"],
    ["a token signed with another secret", async () => await signAccessToken(USER, "another-signing-secret-0123456789abcdef", "1d")],
  ];
  for (const [name, makeToken] of notOurs) {
    it(`answers 401 for ${name}, and nothing else happens`, async () => {
      script();
      const context = new RecordingContext();

      const response = await worker.fetch(
        requestFor("DELETE", await makeToken()),
        environment(),
        context as unknown as ExecutionContext,
      );

      assert.equal(response.status, 401);
      assert.deepEqual(await response.json(), { error: "authentication required" });
      assert.deepEqual(queries, []);
      assert.deepEqual(outsideCalls, []);
      assert.equal(context.promises.length, 0);
    });
  }
});

describe("DELETE /v1/users/me through the router: the rate limit", () => {
  it("answers 429 with retry-after on the sixth request of the hour, before the account is even read", async () => {
    script({ rateCount: 6, appleSub: "dev:someone" });
    const token = await signAccessToken(USER, JWT_SECRET, "1d");
    const context = new RecordingContext();

    const response = await worker.fetch(requestFor("DELETE", token), environment(), context as unknown as ExecutionContext);

    assert.equal(response.status, 429);
    assert.deepEqual(await response.json(), { error: "too many requests" });
    const retryAfter = Number(response.headers.get("retry-after"));
    assert.ok(Number.isInteger(retryAfter) && retryAfter >= 1 && retryAfter <= 3600, `retry-after was ${retryAfter}`);
    assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN, "the answer goes through withCors");
    assert.equal(statement(/rate_limit_counters/)?.values[0], `account-delete:${USER}`, "the person is counted, not the address");
    assert.equal(statement(/FROM app_users/), undefined, "the account was not read");
    assert.equal(statement(/WITH deleted_clips/), undefined);
    assert.deepEqual(outsideCalls, []);
    assert.equal(context.promises.length, 0);
  });

  it("lets the fifth request of the hour through, and counts in one-hour windows", async () => {
    script({ rateCount: 5, appleSub: null });
    const token = await signAccessToken(USER, JWT_SECRET, "1d");
    const before = Date.now();

    const response = await worker.fetch(
      requestFor("DELETE", token),
      environment(),
      new RecordingContext() as unknown as ExecutionContext,
    );
    const after = Date.now();

    assert.equal(response.status, 204, "the limit is five an hour: the fifth is served");
    const windowStart = Date.parse(String(statement(/rate_limit_counters/)?.values[1]));
    assert.ok(
      windowStart === Math.floor(before / HOUR_MS) * HOUR_MS || windowStart === Math.floor(after / HOUR_MS) * HOUR_MS,
      `the window starts on an hour boundary, not at ${new Date(windowStart).toISOString()}`,
    );
  });
});

describe("DELETE /v1/users/me through the router: the handler is reached", () => {
  it("answers 204 and does nothing else when the account is already gone", async () => {
    script({ appleSub: null });
    const token = await signAccessToken(USER, JWT_SECRET, "1d");
    const context = new RecordingContext();

    const response = await worker.fetch(requestFor("DELETE", token), environment(), context as unknown as ExecutionContext);

    assert.equal(response.status, 204);
    assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN, "the answer goes through withCors");
    assert.deepEqual(statement(/FROM app_users/)?.values, [USER], "the handler was given the id from the token");
    assert.equal(statement(/FROM feed_videos/), undefined);
    assert.equal(statement(/WITH deleted_clips/), undefined);
    assert.deepEqual(outsideCalls, []);
    assert.equal(context.promises.length, 0, "nothing to finish after the response");
  });

  it("deletes a test account with no clips and no avatar, and hands the work to waitUntil", async () => {
    script({ appleSub: "dev:someone" });
    const token = await signAccessToken(USER, JWT_SECRET, "1d");
    const context = new RecordingContext();

    const response = await worker.fetch(requestFor("DELETE", token), environment(), context as unknown as ExecutionContext);

    assert.equal(response.status, 204);
    assert.equal(response.headers.get("access-control-allow-origin"), ORIGIN, "the answer goes through withCors");
    assert.equal(context.promises.length, 1, "the deletion is given to waitUntil once");
    assert.equal(((await context.promises[0]) as Response).status, 204, "the promise is the deletion, and it ended well");
    const deletions = queries.filter((query) => /WITH deleted_clips/.test(query.text));
    assert.equal(deletions.length, 1);
    assert.deepEqual(deletions[0].values, [USER, USER]);
    assert.deepEqual(outsideCalls, [], "a test account has no Apple grant, so Apple is not asked");
  });

  it("serves a request that comes without a context: the default context does nothing", async () => {
    script({ appleSub: "dev:someone" });
    const token = await signAccessToken(USER, JWT_SECRET, "1d");

    const response = await worker.fetch(requestFor("DELETE", token), environment());

    assert.equal(response.status, 204);
    assert.equal(queries.filter((query) => /WITH deleted_clips/.test(query.text)).length, 1);
  });
});

describe("/v1/users/me keeps its other methods", () => {
  it("answers POST with 405 even for a valid token, and runs nothing", async () => {
    script({ appleSub: "dev:someone" });
    const token = await signAccessToken(USER, JWT_SECRET, "1d");

    const response = await worker.fetch(requestFor("POST", token), environment(), new RecordingContext() as unknown as ExecutionContext);

    assert.equal(response.status, 405);
    assert.deepEqual(await response.json(), { error: "method not allowed" });
    assert.deepEqual(queries, []);
  });

  it("answers the browser's OPTIONS preflight with 204 and lists DELETE", async () => {
    script();

    const response = await worker.fetch(requestFor("OPTIONS", null), environment(), new RecordingContext() as unknown as ExecutionContext);

    assert.equal(response.status, 204);
    assert.match(response.headers.get("access-control-allow-methods") ?? "", /\bDELETE\b/);
    assert.deepEqual(queries, []);
  });
});
