import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import worker from "../src/index";
import { queries, resetFakeNeon } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const DB_PASSWORD = "pw-for-the-health-test";
const DATABASE_URL = `postgres://user:${DB_PASSWORD}@fake.invalid/test`;
const JWT_SECRET = "health-test-signing-secret-0123456789abcdef";

async function getHealth(env: Record<string, unknown>): Promise<{ response: Response; text: string }> {
  const response = await worker.fetch(new Request("https://api.test/health"), env as never);
  return { response, text: await response.text() };
}

describe("GET /health", () => {
  beforeEach(() => resetFakeNeon());

  it("answers environment and version", async () => {
    for (const environment of ["staging", "production"]) {
      const { response, text } = await getHealth({ ENVIRONMENT: environment, GIT_SHA: "1d02680" });
      assert.equal(response.status, 200);
      assert.deepEqual(JSON.parse(text), { status: "ok", environment, version: "1d02680" });
    }
  });

  it("is never cached, so a deploy check sees the version that answers now", async () => {
    const { response } = await getHealth({ ENVIRONMENT: "staging", GIT_SHA: "1d02680" });
    assert.match(response.headers.get("cache-control") ?? "", /no-store/);
  });

  it("reads unknown and dev when the values are not set", async () => {
    const { response, text } = await getHealth({});
    assert.equal(response.status, 200);
    assert.deepEqual(JSON.parse(text), { status: "ok", environment: "unknown", version: "dev" });
  });

  it("holds nothing else in the body", async () => {
    const { text } = await getHealth({
      ENVIRONMENT: "staging",
      GIT_SHA: "abc1234",
      DATABASE_URL,
      JWT_SIGNING_SECRET: JWT_SECRET,
      DEV_LOGIN_SECRET: "dev-login-secret-for-the-health-test",
    });
    assert.deepEqual(Object.keys(JSON.parse(text)).sort(), ["environment", "status", "version"]);
    for (const secret of [DB_PASSWORD, JWT_SECRET, "dev-login-secret-for-the-health-test"]) {
      assert.ok(!text.includes(secret), "no secret may appear in the body");
    }
  });

  it("needs no database", async () => {
    await getHealth({ ENVIRONMENT: "staging", GIT_SHA: "abc1234", DATABASE_URL });
    assert.equal(queries.length, 0);
  });
});
