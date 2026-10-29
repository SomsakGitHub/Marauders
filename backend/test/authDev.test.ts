import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { authenticateBearerRequest } from "../src/auth/authenticateRequest";
import { handleDevAuth } from "../src/routes/authDev";
import { failNextUpserts, resetFakeUsers, upsertCalls } from "./fakes/users";

// Throwaway values made up for the tests; none of them is a real secret.
const DEV_SECRET = "test-dev-login-secret-0123456789abcdef";
const JWT_SECRET = "test-jwt-signing-secret-0123456789abcdef";
const DATABASE_URL = "postgres://fake.invalid/test";

type TestEnv = {
  DEV_LOGIN_SECRET?: string;
  DATABASE_URL?: string;
  JWT_SIGNING_SECRET?: string;
};

function makeEnv(overrides: TestEnv = {}): never {
  return {
    DEV_LOGIN_SECRET: DEV_SECRET,
    DATABASE_URL,
    JWT_SIGNING_SECRET: JWT_SECRET,
    ...overrides,
  } as never;
}

function post(body: unknown, env: never = makeEnv()): Promise<Response> {
  const raw = typeof body === "string" ? body : JSON.stringify(body);
  return handleDevAuth(
    new Request("https://api.test/v1/auth/dev", { method: "POST", body: raw }),
    env,
  );
}

const valid = { secret: DEV_SECRET, label: "alice" };

describe("POST /v1/auth/dev", () => {
  beforeEach(() => resetFakeUsers());

  describe("when the route is not enabled", () => {
    it("404s when DEV_LOGIN_SECRET is unset", async () => {
      const res = await post(valid, makeEnv({ DEV_LOGIN_SECRET: undefined }));
      assert.equal(res.status, 404);
      assert.equal(typeof (await res.json() as { error: unknown }).error, "string");
      assert.equal(upsertCalls.length, 0);
    });

    it("404s when DEV_LOGIN_SECRET is shorter than 32 chars, even if it matches", async () => {
      const short = "x".repeat(31);
      const res = await post({ secret: short, label: "alice" }, makeEnv({ DEV_LOGIN_SECRET: short }));
      assert.equal(res.status, 404);
      assert.equal(upsertCalls.length, 0);
    });

    it("accepts a secret of exactly 32 chars", async () => {
      const exact = "y".repeat(32);
      const res = await post({ secret: exact, label: "alice" }, makeEnv({ DEV_LOGIN_SECRET: exact }));
      assert.equal(res.status, 200);
    });
  });

  describe("service configuration", () => {
    it("503s when DATABASE_URL is missing", async () => {
      const res = await post(valid, makeEnv({ DATABASE_URL: undefined }));
      assert.equal(res.status, 503);
    });

    it("503s when JWT_SIGNING_SECRET is missing", async () => {
      const res = await post(valid, makeEnv({ JWT_SIGNING_SECRET: undefined }));
      assert.equal(res.status, 503);
    });

    it("503s when JWT_SIGNING_SECRET is shorter than 32 chars", async () => {
      const res = await post(valid, makeEnv({ JWT_SIGNING_SECRET: "s".repeat(31) }));
      assert.equal(res.status, 503);
    });
  });

  describe("request body", () => {
    it("400s on a body that is not JSON", async () => {
      const res = await post("not json {");
      assert.equal(res.status, 400);
    });

    it("400s on JSON that is not an object", async () => {
      for (const body of ["42", "\"text\"", "null", "true"]) {
        const res = await post(body);
        assert.equal(res.status, 400, body);
      }
    });
  });

  describe("secret", () => {
    it("401s when secret is missing or not a string", async () => {
      for (const secret of [undefined, 123, null, ["x"], { a: 1 }]) {
        const res = await post({ secret, label: "alice" });
        assert.equal(res.status, 401, JSON.stringify(secret));
      }
    });

    it("401s when secret does not match", async () => {
      for (const secret of ["", "wrong", DEV_SECRET + "x", DEV_SECRET.slice(0, -1)]) {
        const res = await post({ secret, label: "alice" });
        assert.equal(res.status, 401, secret);
      }
      assert.equal(upsertCalls.length, 0);
    });

    it("checks the secret before the label", async () => {
      const res = await post({ secret: "wrong", label: "BAD LABEL" });
      assert.equal(res.status, 401);
    });
  });

  describe("label", () => {
    it("400s when label is missing, not a string, or malformed", async () => {
      const bad: unknown[] = [
        undefined,
        7,
        null,
        "",
        "Alice",
        "has space",
        "dot.dot",
        "emoji\u{1F600}",
        "a".repeat(33),
        "line\nbreak",
      ];
      for (const label of bad) {
        const res = await post({ secret: DEV_SECRET, label });
        assert.equal(res.status, 400, JSON.stringify(label));
      }
      assert.equal(upsertCalls.length, 0);
    });

    it("accepts the allowed characters and the 1 and 32 length limits", async () => {
      for (const label of ["a", "a".repeat(32), "a-b_c-9"]) {
        const res = await post({ secret: DEV_SECRET, label });
        assert.equal(res.status, 200, label);
      }
    });
  });

  describe("country", () => {
    it("400s on a country that is not 2 letters", async () => {
      for (const country of ["T", "THA", "1A", "", "T H", 12, true, ["TH"]]) {
        const res = await post({ ...valid, country });
        assert.equal(res.status, 400, JSON.stringify(country));
      }
      assert.equal(upsertCalls.length, 0);
    });

    it("upper-cases a valid country", async () => {
      const res = await post({ ...valid, country: "th" });
      assert.equal(res.status, 200);
      assert.equal(upsertCalls[0].country, "TH");
    });

    it("passes null when country is omitted or null", async () => {
      await post(valid);
      await post({ ...valid, country: null });
      assert.deepEqual(upsertCalls.map((c) => c.country), [null, null]);
    });
  });

  describe("success", () => {
    it("returns 200 with only an accessToken", async () => {
      const res = await post(valid);
      assert.equal(res.status, 200);
      assert.match(res.headers.get("content-type") ?? "", /application\/json/);
      assert.equal(res.headers.get("cache-control"), "private, max-age=0, no-store");
      const json = (await res.json()) as Record<string, unknown>;
      assert.deepEqual(Object.keys(json), ["accessToken"]);
      assert.equal(typeof json.accessToken, "string");
    });

    it("upserts apple_sub dev:<label> with the configured database", async () => {
      await post({ ...valid, country: "us" });
      assert.deepEqual(upsertCalls, [
        { databaseUrl: DATABASE_URL, appleSub: "dev:alice", country: "US" },
      ]);
    });

    it("gives the same user for the same label and different users for different labels", async () => {
      const subjectOf = async (label: string) => {
        const res = await post({ secret: DEV_SECRET, label });
        const { accessToken } = (await res.json()) as { accessToken: string };
        const auth = await authenticateBearerRequest(
          new Request("https://api.test/", { headers: { Authorization: `Bearer ${accessToken}` } }),
          JWT_SECRET,
        );
        assert.ok(auth, "token should authenticate");
        return auth.userId;
      };
      const first = await subjectOf("alice");
      const second = await subjectOf("alice");
      const other = await subjectOf("bob");
      assert.equal(first, second);
      assert.notEqual(first, other);
    });

    it("returns a token that authenticateBearerRequest accepts and only for the right secret", async () => {
      const res = await post(valid);
      const { accessToken } = (await res.json()) as { accessToken: string };
      const request = new Request("https://api.test/", {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      const auth = await authenticateBearerRequest(request, JWT_SECRET);
      assert.match(auth?.userId ?? "", /^00000000-0000-4000-8000-/);
      assert.equal(await authenticateBearerRequest(request, "z".repeat(40)), null);
    });
  });

  describe("failures", () => {
    it("500s with a generic message and leaks no detail when the database fails", async () => {
      failNextUpserts(new Error("connection to neon-host-secret.example refused password=hunter2"));
      const res = await post(valid);
      assert.equal(res.status, 500);
      const text = await res.text();
      assert.deepEqual(JSON.parse(text), { error: "dev login failed" });
      for (const leak of ["neon", "hunter2", "refused", DEV_SECRET, JWT_SECRET, DATABASE_URL]) {
        assert.ok(!text.includes(leak), `response leaked ${leak}`);
      }
    });
  });
});
