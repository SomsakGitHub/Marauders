import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { decodeJwt } from "jose";

import { signAccessToken } from "../src/auth/accessToken";
import {
  generateRefreshToken,
  hashRefreshToken,
  isWellFormedRefreshToken,
} from "../src/auth/refreshToken";

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
