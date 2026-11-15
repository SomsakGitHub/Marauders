import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { decodeJwt } from "jose";

import { signAccessToken, verifyAccessToken } from "../src/auth/accessToken";
import {
  generateRefreshToken,
  hashRefreshToken,
  isWellFormedRefreshToken,
} from "../src/auth/refreshToken";
import {
  issueRefreshToken,
  revokeRefreshFamily,
  rotateRefreshToken,
} from "../src/db/refreshTokens";
import worker from "../src/index";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const JWT_SECRET = "auth-refresh-test-signing-secret-0123456789abcdef";
const USER = "11111111-1111-4111-8111-111111111111";
const DATABASE_URL = "postgres://fake.invalid/test";

const DAY = 86400;

describe("primitives", () => {
  describe("generateRefreshToken", () => {
    it("returns 43 base64url characters", () => {
      assert.match(generateRefreshToken(), /^[A-Za-z0-9_-]{43}$/);
    });

    it("never repeats", () => {
      const tokens = new Set(Array.from({ length: 1000 }, () => generateRefreshToken()));
      assert.equal(tokens.size, 1000);
    });
  });

  describe("isWellFormedRefreshToken", () => {
    it("accepts a generated token", () => {
      assert.equal(isWellFormedRefreshToken(generateRefreshToken()), true);
    });

    const malformed: Array<[string, unknown]> = [
      ["undefined", undefined],
      ["a number", 5],
      ["an empty string", ""],
      ["42 characters", "a".repeat(42)],
      ["44 characters", "a".repeat(44)],
      ["a plus sign", `${"a".repeat(42)}+`],
      ["an equals sign", `${"a".repeat(42)}=`],
      ["a space", `${"a".repeat(42)} `],
    ];
    for (const [name, value] of malformed) {
      it(`rejects ${name}`, () => {
        assert.equal(isWellFormedRefreshToken(value), false);
      });
    }
  });

  describe("hashRefreshToken", () => {
    it("is the lowercase hex SHA-256 of the token", async () => {
      assert.equal(
        await hashRefreshToken("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      );
    });

    it("always gives 64 lowercase hex characters", async () => {
      assert.match(await hashRefreshToken(generateRefreshToken()), /^[a-f0-9]{64}$/);
    });
  });

  describe("signAccessToken", () => {
    it("lasts 30 days unless told otherwise", async () => {
      const claims = decodeJwt(await signAccessToken(USER, JWT_SECRET));
      assert.equal(claims.sub, USER);
      assert.equal((claims.exp ?? 0) - (claims.iat ?? 0), 30 * DAY);
    });

    it("lasts 30 days when asked for 30d", async () => {
      const claims = decodeJwt(await signAccessToken(USER, JWT_SECRET, "30d"));
      assert.equal((claims.exp ?? 0) - (claims.iat ?? 0), 30 * DAY);
    });

    it("lasts 1 day when asked for 1d", async () => {
      const claims = decodeJwt(await signAccessToken(USER, JWT_SECRET, "1d"));
      assert.equal(claims.sub, USER);
      assert.equal((claims.exp ?? 0) - (claims.iat ?? 0), DAY);
    });
  });
});

describe("refresh token statements", () => {
  // The fake Neon runs no SQL: these tests pin how many statements run, in which order, and with which values.
  // The SQL itself is proven on a real engine in the PGlite check (plan Task 5).
  const PRESENTED = "a".repeat(64);
  const SUCCESSOR = "b".repeat(64);

  beforeEach(() => resetFakeNeon());

  /** Answers the first statement with the first list of rows, the second with the second, and so on; later ones get none. */
  function answerInOrder(...rows: unknown[][]): void {
    let next = 0;
    respondWith(() => rows[next++] ?? []);
  }

  describe("issueRefreshToken", () => {
    it("inserts one row that starts a new family, with the user, the hash and 90 days", async () => {
      await issueRefreshToken(DATABASE_URL, USER, PRESENTED);

      assert.equal(queries.length, 1);
      assert.match(queries[0].text, /INSERT INTO refresh_tokens/);
      assert.match(queries[0].text, /gen_random_uuid\(\)/);
      assert.ok(queries[0].values.includes(USER));
      assert.ok(queries[0].values.includes(PRESENTED));
      assert.ok(queries[0].values.includes(90));
    });
  });

  describe("rotateRefreshToken", () => {
    it("rotates a token that was never used in one statement", async () => {
      answerInOrder([{ user_id: USER }]);

      const result = await rotateRefreshToken(DATABASE_URL, PRESENTED, SUCCESSOR);

      assert.deepEqual(result, { kind: "rotated", userId: USER });
      assert.equal(queries.length, 1);
      assert.match(queries[0].text, /UPDATE refresh_tokens[\s\S]*used_at IS NULL[\s\S]*INSERT INTO refresh_tokens/);
      assert.ok(queries[0].values.includes(PRESENTED));
      assert.ok(queries[0].values.includes(SUCCESSOR));
      assert.ok(queries[0].values.includes(90));
    });

    it("rotates again, in a second statement, for a token used less than 60 seconds ago", async () => {
      answerInOrder([], [{ user_id: USER }]);

      const result = await rotateRefreshToken(DATABASE_URL, PRESENTED, SUCCESSOR);

      assert.deepEqual(result, { kind: "rotated", userId: USER });
      assert.equal(queries.length, 2);
      assert.match(queries[1].text, /used_at > now\(\) - make_interval/);
      assert.ok(queries[1].values.includes(60));
      assert.ok(queries[1].values.includes(PRESENTED));
      assert.ok(queries[1].values.includes(SUCCESSOR));
    });

    it("rejects a reused token and revokes its family in a third statement", async () => {
      answerInOrder([], []);

      const result = await rotateRefreshToken(DATABASE_URL, PRESENTED, SUCCESSOR);

      assert.deepEqual(result, { kind: "rejected" });
      assert.equal(queries.length, 3);
      assert.match(queries[2].text, /SET revoked_at = now\(\)/);
      assert.ok(queries[2].values.includes(PRESENTED));
      assert.ok(!queries[2].values.includes(SUCCESSOR));
    });
  });

  describe("revokeRefreshFamily", () => {
    it("revokes the family of the token in one statement that has the hash as its only value", async () => {
      await revokeRefreshFamily(DATABASE_URL, PRESENTED);

      assert.equal(queries.length, 1);
      assert.match(queries[0].text, /UPDATE refresh_tokens[\s\S]*SET revoked_at = now\(\)/);
      assert.deepEqual(queries[0].values, [PRESENTED]);
    });

    it("resolves when no row matched", async () => {
      answerInOrder([]);
      assert.equal(await revokeRefreshFamily(DATABASE_URL, PRESENTED), undefined);
    });
  });

  describe("a database failure", () => {
    it("is passed on by every function, never turned into a rejection", async () => {
      const failure = new Error("database unavailable");
      respondWith(() => {
        throw failure;
      });

      await assert.rejects(rotateRefreshToken(DATABASE_URL, PRESENTED, SUCCESSOR), failure);
      await assert.rejects(issueRefreshToken(DATABASE_URL, USER, PRESENTED), failure);
      await assert.rejects(revokeRefreshFamily(DATABASE_URL, PRESENTED), failure);
    });

    it("on a later rotation statement is passed on too", async () => {
      const failure = new Error("database unavailable");
      let calls = 0;
      respondWith(() => {
        calls += 1;
        if (calls === 1) return [];
        throw failure;
      });

      await assert.rejects(rotateRefreshToken(DATABASE_URL, PRESENTED, SUCCESSOR), failure);
      assert.equal(queries.length, 2);
    });
  });
});

// Helpers for the tests that go through worker.fetch.

const baseEnv = { DATABASE_URL, JWT_SIGNING_SECRET: JWT_SECRET };

type Pair = { accessToken: string; refreshToken: string };

type Script = {
  /** What the Neon rate counter answers: 31 is over the limit of 30. */
  rateCount?: number;
  /** Rows for the first, second, ... refresh_tokens statement; later ones get none. */
  rows?: unknown[][];
  /** Makes every refresh_tokens statement fail with this error. */
  failWith?: Error;
  /** The id the user upsert answers; USER when left out. */
  userId?: string;
};

/** Answers rate-limit statements and the user upsert itself, and refresh_tokens statements as the test scripts them. */
function script(s: Script = {}): void {
  let next = 0;
  respondWith((query) => {
    if (/rate_limit_counters/.test(query.text)) return [{ count: s.rateCount ?? 1 }];
    if (/INSERT INTO app_users/.test(query.text)) return [{ id: s.userId ?? USER }];
    if (/refresh_tokens/.test(query.text)) {
      if (s.failWith) throw s.failWith;
      return s.rows?.[next++] ?? [];
    }
    throw new Error(`unexpected statement: ${query.text}`);
  });
}

const refreshStatements = () => queries.filter((query) => /refresh_tokens/.test(query.text));

function post(path: string, body: unknown, env: object = baseEnv): Promise<Response> {
  const raw = typeof body === "string" ? body : JSON.stringify(body);
  return worker.fetch(
    new Request(`https://api.test${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: raw,
    }),
    env as never,
  );
}

describe("the refresh and sign-out routes", () => {
  const refresh = (body: unknown, env?: object) => post("/v1/auth/refresh", body, env);
  const signOut = (body: unknown, env?: object) => post("/v1/auth/signout", body, env);

  const wrongShapes: unknown[] = [
    {},
    { refreshToken: 5 },
    { refreshToken: "a".repeat(42) },
    { refreshToken: "a".repeat(44) },
    { refreshToken: `${"a".repeat(42)}+` },
    "this is not json",
    [],
    null,
  ];

  beforeEach(() => {
    resetFakeNeon();
    script();
  });

  describe("POST /v1/auth/refresh", () => {
    const presented = generateRefreshToken();

    it("answers 400 to a body of the wrong shape and touches no token", async () => {
      for (const body of wrongShapes) {
        assert.equal((await refresh(body)).status, 400, JSON.stringify(body));
      }
      assert.equal(refreshStatements().length, 0);
    });

    it("rotates a token on first use and answers a pair with a 1-day access token", async () => {
      script({ rows: [[{ user_id: USER }]] });

      const res = await refresh({ refreshToken: presented });

      assert.equal(res.status, 200);
      assert.equal(res.headers.get("cache-control"), "private, max-age=0, no-store");
      const pair = (await res.json()) as Pair;
      assert.deepEqual(Object.keys(pair).sort(), ["accessToken", "refreshToken"]);
      assert.ok(isWellFormedRefreshToken(pair.refreshToken));
      assert.notEqual(pair.refreshToken, presented);

      const statements = refreshStatements();
      assert.equal(statements.length, 1);
      assert.ok(statements[0].values.includes(await hashRefreshToken(presented)));
      assert.ok(statements[0].values.includes(await hashRefreshToken(pair.refreshToken)));
      assert.ok(!statements[0].values.includes(pair.refreshToken), "a raw token is never stored");

      assert.deepEqual(await verifyAccessToken(pair.accessToken, JWT_SECRET), { sub: USER });
      const claims = decodeJwt(pair.accessToken);
      assert.equal((claims.exp ?? 0) - (claims.iat ?? 0), DAY);
    });

    it("answers a second, different pair for a token used again inside the leeway", async () => {
      script({ rows: [[{ user_id: USER }]] });
      const first = (await (await refresh({ refreshToken: presented })).json()) as Pair;

      resetFakeNeon();
      script({ rows: [[], [{ user_id: USER }]] });
      const res = await refresh({ refreshToken: presented });

      assert.equal(res.status, 200);
      const second = (await res.json()) as Pair;
      assert.notEqual(second.refreshToken, first.refreshToken);
      assert.notEqual(second.refreshToken, presented);
      assert.equal(refreshStatements().length, 2);
      assert.deepEqual(await verifyAccessToken(second.accessToken, JWT_SECRET), { sub: USER });
    });

    it("is 401 with one body for an unknown, revoked, expired or reused token, and revokes the family", async () => {
      const res = await refresh({ refreshToken: presented });

      assert.equal(res.status, 401);
      assert.equal(await res.text(), '{"error":"invalid refresh token"}');
      const statements = refreshStatements();
      assert.equal(statements.length, 3);
      assert.match(statements[2].text, /SET revoked_at = now\(\)/);
      assert.ok(statements[2].values.includes(await hashRefreshToken(presented)));
    });

    it("is 500, never an auth answer, when the database fails", async () => {
      script({ failWith: new Error("connection reset, detail secret-detail") });

      const res = await refresh({ refreshToken: presented });

      assert.equal(res.status, 500);
      assert.ok(!(await res.text()).includes("secret-detail"));
    });

    it("answers 503 without a database or a signing secret of at least 32 characters", async () => {
      const body = { refreshToken: presented };
      assert.equal((await refresh(body, { DATABASE_URL })).status, 503);
      assert.equal((await refresh(body, { DATABASE_URL, JWT_SIGNING_SECRET: "too-short" })).status, 503);
      assert.equal((await refresh(body, { JWT_SIGNING_SECRET: JWT_SECRET })).status, 503);
      assert.equal(refreshStatements().length, 0);
    });
  });

  describe("POST /v1/auth/signout", () => {
    const presented = generateRefreshToken();

    it("answers 204 without a Bearer token, for a known and for an unknown token, revoking the family each time", async () => {
      const hash = await hashRefreshToken(presented);
      for (const attempt of [1, 2]) {
        const res = await signOut({ refreshToken: presented });
        assert.equal(res.status, 204, `attempt ${attempt}`);
        assert.equal(await res.text(), "");
      }
      const statements = refreshStatements();
      assert.equal(statements.length, 2);
      for (const statement of statements) {
        assert.match(statement.text, /UPDATE refresh_tokens[\s\S]*SET revoked_at = now\(\)/);
        assert.deepEqual(statement.values, [hash]);
      }
    });

    it("answers 400 to a body of the wrong shape and touches no token", async () => {
      for (const body of wrongShapes) {
        assert.equal((await signOut(body)).status, 400, JSON.stringify(body));
      }
      assert.equal(refreshStatements().length, 0);
    });

    it("answers 500 when the database fails", async () => {
      script({ failWith: new Error("connection reset, detail secret-detail") });

      const res = await signOut({ refreshToken: presented });

      assert.equal(res.status, 500);
      assert.ok(!(await res.text()).includes("secret-detail"));
    });

    it("answers 503 without a database", async () => {
      assert.equal((await signOut({ refreshToken: presented }, {})).status, 503);
    });
  });

  describe("rate limit", () => {
    const body = { refreshToken: generateRefreshToken() };

    it("is the auth limit of sign-in: over 30 in the Neon counter is 429 with a retry-after", async () => {
      script({ rateCount: 31 });
      for (const path of ["/v1/auth/refresh", "/v1/auth/signout"]) {
        const res = await post(path, body);
        assert.equal(res.status, 429, path);
        assert.ok(res.headers.get("retry-after"), path);
      }
      assert.equal(refreshStatements().length, 0);
    });

    it("is also the Cloudflare auth limiter binding", async () => {
      const env = { ...baseEnv, AUTH_RATE_LIMITER: { limit: async () => ({ success: false }) } };
      for (const path of ["/v1/auth/refresh", "/v1/auth/signout"]) {
        const res = await post(path, body, env);
        assert.equal(res.status, 429, path);
      }
      assert.equal(refreshStatements().length, 0);
    });

    it("leaves a GET to the refresh path unserved", async () => {
      const res = await worker.fetch(new Request("https://api.test/v1/auth/refresh"), baseEnv as never);
      assert.notEqual(res.status, 200);
      assert.equal(refreshStatements().length, 0);
    });
  });

  describe("logging", () => {
    it("never puts a token or the hash of one in a log line", async () => {
      const lines: string[] = [];
      const names = ["log", "warn", "error", "info"] as const;
      const originals = names.map((name) => console[name]);
      for (const name of names) {
        console[name] = (...args: unknown[]) => {
          lines.push(
            args.map((arg) => (arg instanceof Error ? `${arg.message}\n${arg.stack}` : String(arg))).join(" "),
          );
        };
      }

      const secrets: string[] = [];
      try {
        const presented = generateRefreshToken();
        const presentedHash = await hashRefreshToken(presented);
        secrets.push(presented, presentedHash);

        script({ rows: [[{ user_id: USER }]] });
        const first = (await (await refresh({ refreshToken: presented })).json()) as Pair;
        secrets.push(first.refreshToken, await hashRefreshToken(first.refreshToken));

        resetFakeNeon();
        script({ rows: [[], [{ user_id: USER }]] });
        const second = (await (await refresh({ refreshToken: presented })).json()) as Pair;
        secrets.push(second.refreshToken, await hashRefreshToken(second.refreshToken));

        resetFakeNeon();
        script();
        assert.equal((await refresh({ refreshToken: presented })).status, 401);

        // A driver error that echoes the statement's parameters, as some do: nothing may pass it on.
        resetFakeNeon();
        script({ failWith: new Error(`failed for ${presentedHash} and ${presented}`) });
        assert.equal((await refresh({ refreshToken: presented })).status, 500);
        assert.equal((await signOut({ refreshToken: presented })).status, 500);

        resetFakeNeon();
        script();
        assert.equal((await signOut({ refreshToken: presented })).status, 204);
      } finally {
        names.forEach((name, index) => {
          console[name] = originals[index] as never;
        });
      }

      const logged = lines.join("\n");
      for (const secret of secrets) {
        assert.ok(!logged.includes(secret), "a token or hash reached a log line");
      }
    });
  });
});

describe("sign-in and the refresh token", () => {
  const DEV_SECRET = "test-dev-login-secret-0123456789abcdef";
  const signInEnv = { ...baseEnv, APPLE_CLIENT_ID: "com.example.test", DEV_LOGIN_SECRET: DEV_SECRET };

  const signInRoutes = [
    {
      path: "/v1/auth/apple",
      body: (extra: object) => ({ identityToken: "valid-identity-token-0123456789", ...extra }),
    },
    {
      path: "/v1/auth/dev",
      body: (extra: object) => ({ secret: DEV_SECRET, label: "alice", ...extra }),
    },
  ];

  /** The statements that change what a sign-in stores: the user upsert and the refresh token. */
  const writes = () => queries.filter((query) => /app_users|refresh_tokens/.test(query.text));

  beforeEach(() => {
    resetFakeNeon();
    script();
  });

  for (const route of signInRoutes) {
    describe(`POST ${route.path}`, () => {
      const signIn = (extra: object = {}) => post(route.path, route.body(extra), signInEnv);

      for (const extra of [{}, { supportsRefreshTokens: false }, { supportsRefreshTokens: null }]) {
        it(`answers exactly today's { accessToken }, valid 30 days, to a client that sends ${JSON.stringify(extra)}`, async () => {
          const res = await signIn(extra);

          assert.equal(res.status, 200);
          const body = (await res.json()) as Record<string, unknown>;
          assert.deepEqual(Object.keys(body), ["accessToken"]);
          const claims = decodeJwt(body.accessToken as string);
          assert.equal(claims.sub, USER);
          assert.equal((claims.exp ?? 0) - (claims.iat ?? 0), 30 * DAY);
          assert.equal(refreshStatements().length, 0);
        });
      }

      it("answers a pair with a 1-day access token to a client that asks for a refresh token, and stores only its hash", async () => {
        const res = await signIn({ supportsRefreshTokens: true });

        assert.equal(res.status, 200);
        const pair = (await res.json()) as Pair;
        assert.deepEqual(Object.keys(pair).sort(), ["accessToken", "refreshToken"]);
        const claims = decodeJwt(pair.accessToken);
        assert.equal(claims.sub, USER);
        assert.equal((claims.exp ?? 0) - (claims.iat ?? 0), DAY);
        assert.ok(isWellFormedRefreshToken(pair.refreshToken));

        const inserts = refreshStatements();
        assert.equal(inserts.length, 1);
        assert.match(inserts[0].text, /INSERT INTO refresh_tokens/);
        assert.ok(inserts[0].values.includes(USER));
        assert.ok(inserts[0].values.includes(await hashRefreshToken(pair.refreshToken)));
        assert.ok(!inserts[0].values.includes(pair.refreshToken), "a raw token is never stored");
      });

      it("starts a new family at every sign-in", async () => {
        const first = (await (await signIn({ supportsRefreshTokens: true })).json()) as Pair;
        const second = (await (await signIn({ supportsRefreshTokens: true })).json()) as Pair;

        assert.notEqual(first.refreshToken, second.refreshToken);
        const inserts = refreshStatements();
        assert.equal(inserts.length, 2);
        assert.ok(inserts[0].values.includes(await hashRefreshToken(first.refreshToken)));
        assert.ok(inserts[1].values.includes(await hashRefreshToken(second.refreshToken)));
      });

      for (const flag of ["true", 1, {}, []]) {
        it(`answers 400 to a flag of the wrong type, ${JSON.stringify(flag)}, before anything is written`, async () => {
          const res = await signIn({ supportsRefreshTokens: flag });

          assert.equal(res.status, 400);
          assert.equal(writes().length, 0);
        });
      }

      it("answers 500 and hands out no token when the refresh token cannot be stored", async () => {
        script({ failWith: new Error("insert failed") });

        const res = await signIn({ supportsRefreshTokens: true });

        assert.equal(res.status, 500);
        const text = await res.text();
        assert.ok(!text.includes("accessToken"), text);
        assert.ok(!text.includes("refreshToken"), text);
      });
    });
  }

  it("still answers 401 to an identity token Apple refuses", async () => {
    const res = await post(
      "/v1/auth/apple",
      { identityToken: "invalid-identity-token-0123456789", supportsRefreshTokens: true },
      signInEnv,
    );

    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: "invalid apple identity token" });
    assert.equal(writes().length, 0);
  });
});
