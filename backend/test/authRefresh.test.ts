import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { decodeJwt } from "jose";

import { signAccessToken } from "../src/auth/accessToken";
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
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const JWT_SECRET = "auth-refresh-test-signing-secret-0123456789abcdef";
const USER = "11111111-1111-4111-8111-111111111111";

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
  const DATABASE_URL = "postgres://fake.invalid/test";
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
