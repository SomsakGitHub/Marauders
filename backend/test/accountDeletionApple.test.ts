import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify } from "jose";

import {
  AppleClientError,
  appleCredentialsFromEnv,
  createAppleClientSecret,
  exchangeAuthorizationCode,
  revokeAppleToken,
} from "../src/auth/appleClient";
import type { AppleCredentials, AppleFailure } from "../src/auth/appleClient";

// Throwaway values made up for the tests; none of them is a real credential. The key pair is generated fresh on every run.
const TEAM = "TEAM123456";
const KEY_ID = "KEY1234567";
const CLIENT = "com.example.marauders.test";
const AUDIENCE = "https://appleid.apple.com";
const CODE = "c0de-single-use-authorization-code";
const REFRESH_TOKEN = "r.refresh-token-from-apple";
const ID_TOKEN = "eyJ.identity.token";
const NOW = new Date("2026-11-20T10:00:00Z");

const keys = (async () => {
  const { publicKey, privateKey } = await generateKeyPair("ES256", { extractable: true });
  const pem = await exportPKCS8(privateKey);
  const credentials: AppleCredentials = { teamId: TEAM, keyId: KEY_ID, privateKeyPem: pem, clientId: CLIENT };
  return { publicKey, pem, credentials };
})();

type AppleCall = { url: string; method: string; contentType: string | null; form: URLSearchParams };

/** Apple, as far as the client can tell: it records what was posted and answers with whatever the test hands back. */
function fakeApple(answer: (call: AppleCall) => Response | Promise<Response>) {
  const calls: AppleCall[] = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const call: AppleCall = {
      url: String(input),
      method: init?.method ?? "GET",
      contentType: new Headers(init?.headers).get("content-type"),
      form: new URLSearchParams(String(init?.body ?? "")),
    };
    calls.push(call);
    return await answer(call);
  }) as typeof fetch;
  return { calls, fetchImpl };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const tokenAnswer = () =>
  json(200, {
    access_token: "access-token-from-apple",
    token_type: "Bearer",
    expires_in: 3600,
    refresh_token: REFRESH_TOKEN,
    id_token: ID_TOKEN,
  });

/** The client's one rule for what it throws: an AppleClientError of this kind whose message is the kind and nothing else. */
async function assertFails(action: Promise<unknown>, kind: AppleFailure): Promise<void> {
  await assert.rejects(action, (error: unknown) => {
    assert.ok(error instanceof AppleClientError, "an AppleClientError");
    assert.equal(error.kind, kind);
    assert.equal(error.message, kind, "the message is the kind, never a body, a code or a token");
    return true;
  });
}

describe("appleCredentialsFromEnv", () => {
  const complete = {
    APPLE_TEAM_ID: TEAM,
    APPLE_KEY_ID: KEY_ID,
    APPLE_PRIVATE_KEY: "key text",
    APPLE_CLIENT_ID: CLIENT,
  };

  it("returns the four values when all of them are set", () => {
    assert.deepEqual(appleCredentialsFromEnv(complete), {
      teamId: TEAM,
      keyId: KEY_ID,
      privateKeyPem: "key text",
      clientId: CLIENT,
    });
  });

  for (const name of Object.keys(complete) as Array<keyof typeof complete>) {
    it(`returns null when ${name} is missing`, () => {
      const { [name]: _removed, ...rest } = complete;
      assert.equal(appleCredentialsFromEnv(rest), null);
    });

    it(`returns null when ${name} is empty`, () => {
      assert.equal(appleCredentialsFromEnv({ ...complete, [name]: "" }), null);
    });
  }

  it("drops a pasted trailing newline and treats a blank value as missing", () => {
    assert.equal(appleCredentialsFromEnv({ ...complete, APPLE_TEAM_ID: `${TEAM}\n` })?.teamId, TEAM);
    assert.equal(appleCredentialsFromEnv({ ...complete, APPLE_KEY_ID: "  \n" }), null);
  });
});

describe("createAppleClientSecret", () => {
  it("signs a token that Apple would accept for these credentials", async () => {
    const { credentials, publicKey } = await keys;
    const secret = await createAppleClientSecret(credentials, NOW);

    const { payload, protectedHeader } = await jwtVerify(secret, publicKey, {
      issuer: TEAM,
      subject: CLIENT,
      audience: AUDIENCE,
      currentDate: NOW,
    });
    assert.equal(protectedHeader.alg, "ES256");
    assert.equal(protectedHeader.kid, KEY_ID);
    assert.equal(decodeProtectedHeader(secret).kid, KEY_ID);
    assert.equal(payload.iat, Math.floor(NOW.getTime() / 1000));
  });

  it("expires five minutes after it was issued", async () => {
    const { credentials, publicKey } = await keys;
    const { payload } = await jwtVerify(await createAppleClientSecret(credentials, NOW), publicKey, {
      currentDate: NOW,
    });
    assert.equal((payload.exp ?? 0) - (payload.iat ?? 0), 300);
  });

  it("signs with a key whose newlines are real and with the same key written with backslash-n escapes", async () => {
    const { credentials, publicKey, pem } = await keys;
    const escaped = pem.replaceAll("\n", "\\n");
    assert.ok(pem.includes("\n") && !pem.includes("\\n"), "the exported key has real newlines");
    assert.ok(escaped.includes("\\n") && !escaped.includes("\n"), "the escaped key has none");

    for (const privateKeyPem of [pem, escaped]) {
      const secret = await createAppleClientSecret({ ...credentials, privateKeyPem }, NOW);
      await jwtVerify(secret, publicKey, { issuer: TEAM, subject: CLIENT, audience: AUDIENCE, currentDate: NOW });
    }
  });

  it("throws invalid_client for a key that is not a PEM, without repeating what it was given", async () => {
    const { credentials } = await keys;
    await assertFails(
      createAppleClientSecret({ ...credentials, privateKeyPem: "NOT-A-KEY-secret-looking-text" }, NOW),
      "invalid_client",
    );
  });
});

describe("exchangeAuthorizationCode", () => {
  it("posts the code to Apple's token endpoint as a form", async () => {
    const { credentials, publicKey } = await keys;
    const apple = fakeApple(() => tokenAnswer());

    await exchangeAuthorizationCode(credentials, CODE, apple.fetchImpl);

    assert.equal(apple.calls.length, 1);
    const [call] = apple.calls;
    assert.equal(call.url, "https://appleid.apple.com/auth/token");
    assert.equal(call.method, "POST");
    assert.equal(call.contentType, "application/x-www-form-urlencoded");
    // Exactly these four: the native sign-in sent no redirect_uri, so none is sent back.
    assert.deepEqual([...call.form.keys()].sort(), ["client_id", "client_secret", "code", "grant_type"]);
    assert.equal(call.form.get("client_id"), CLIENT);
    assert.equal(call.form.get("code"), CODE);
    assert.equal(call.form.get("grant_type"), "authorization_code");
    await jwtVerify(call.form.get("client_secret") ?? "", publicKey, {
      issuer: TEAM,
      subject: CLIENT,
      audience: AUDIENCE,
    });
  });

  it("returns the identity token and the refresh token", async () => {
    const { credentials } = await keys;
    const apple = fakeApple(() => tokenAnswer());

    assert.deepEqual(await exchangeAuthorizationCode(credentials, CODE, apple.fetchImpl), {
      idToken: ID_TOKEN,
      refreshToken: REFRESH_TOKEN,
    });
  });

  const failures: Array<[string, () => Response, AppleFailure]> = [
    ["a 200 without a refresh token", () => json(200, { id_token: ID_TOKEN }), "unavailable"],
    ["a 200 without an identity token", () => json(200, { refresh_token: REFRESH_TOKEN }), "unavailable"],
    ["a 200 whose tokens are not strings", () => json(200, { id_token: 5, refresh_token: {} }), "unavailable"],
    ["a 200 whose body is not JSON", () => new Response("<html>not json</html>", { status: 200 }), "unavailable"],
    ["a 400 invalid_grant", () => json(400, { error: "invalid_grant" }), "invalid_grant"],
    ["a 400 invalid_client", () => json(400, { error: "invalid_client" }), "invalid_client"],
    ["a 401 invalid_client", () => json(401, { error: "invalid_client" }), "invalid_client"],
    ["a 400 invalid_request", () => json(400, { error: "invalid_request" }), "unavailable"],
    ["a 400 whose body is not JSON", () => new Response("a page from a proxy", { status: 400 }), "unavailable"],
    ["a 500", () => new Response("", { status: 500 }), "unavailable"],
    ["a 500 that says invalid_grant", () => json(500, { error: "invalid_grant" }), "unavailable"],
  ];
  for (const [name, answer, kind] of failures) {
    it(`fails with ${kind} on ${name}`, async () => {
      const { credentials } = await keys;
      const apple = fakeApple(() => answer());
      await assertFails(exchangeAuthorizationCode(credentials, CODE, apple.fetchImpl), kind);
    });
  }

  it("fails with unavailable when the request itself fails", async () => {
    const { credentials } = await keys;
    const fetchImpl = (async () => {
      throw new TypeError(`network down while sending ${CODE}`);
    }) as typeof fetch;
    await assertFails(exchangeAuthorizationCode(credentials, CODE, fetchImpl), "unavailable");
  });

  it("does not call Apple when the key cannot be read", async () => {
    const { credentials } = await keys;
    const apple = fakeApple(() => tokenAnswer());
    await assertFails(
      exchangeAuthorizationCode({ ...credentials, privateKeyPem: "not a key" }, CODE, apple.fetchImpl),
      "invalid_client",
    );
    assert.equal(apple.calls.length, 0);
  });

  it("never repeats the code, a token, the key or Apple's own words in what it throws", async () => {
    const { credentials, pem } = await keys;
    const apple = fakeApple(() =>
      json(400, { error: "invalid_grant", error_description: `bad ${CODE} and ${REFRESH_TOKEN}` }),
    );

    const error = await exchangeAuthorizationCode(credentials, CODE, apple.fetchImpl).then(
      () => undefined,
      (caught: unknown) => caught,
    );

    assert.ok(error instanceof AppleClientError);
    const everything = `${error.message}\n${error.stack}\n${JSON.stringify(error)}`;
    for (const secret of [CODE, REFRESH_TOKEN, "error_description", pem.slice(40, 80)]) {
      assert.ok(!everything.includes(secret), `the error leaks "${secret.slice(0, 12)}…"`);
    }
  });
});

describe("revokeAppleToken", () => {
  it("posts the refresh token to Apple's revoke endpoint as a form", async () => {
    const { credentials, publicKey } = await keys;
    const apple = fakeApple(() => new Response(null, { status: 200 }));

    assert.equal(await revokeAppleToken(credentials, REFRESH_TOKEN, apple.fetchImpl), undefined);

    assert.equal(apple.calls.length, 1);
    const [call] = apple.calls;
    assert.equal(call.url, "https://appleid.apple.com/auth/revoke");
    assert.equal(call.method, "POST");
    assert.equal(call.contentType, "application/x-www-form-urlencoded");
    assert.deepEqual([...call.form.keys()].sort(), ["client_id", "client_secret", "token", "token_type_hint"]);
    assert.equal(call.form.get("client_id"), CLIENT);
    assert.equal(call.form.get("token"), REFRESH_TOKEN);
    assert.equal(call.form.get("token_type_hint"), "refresh_token");
    await jwtVerify(call.form.get("client_secret") ?? "", publicKey, {
      issuer: TEAM,
      subject: CLIENT,
      audience: AUDIENCE,
    });
  });

  const failures: Array<[string, () => Response, AppleFailure]> = [
    ["a 400 invalid_client", () => json(400, { error: "invalid_client" }), "invalid_client"],
    ["a 401 invalid_client", () => json(401, { error: "invalid_client" }), "invalid_client"],
    ["a 400 invalid_request", () => json(400, { error: "invalid_request" }), "unavailable"],
    ["a 500", () => new Response("", { status: 500 }), "unavailable"],
  ];
  for (const [name, answer, kind] of failures) {
    it(`fails with ${kind} on ${name}`, async () => {
      const { credentials } = await keys;
      const apple = fakeApple(() => answer());
      await assertFails(revokeAppleToken(credentials, REFRESH_TOKEN, apple.fetchImpl), kind);
    });
  }

  it("fails with unavailable when the request itself fails", async () => {
    const { credentials } = await keys;
    const fetchImpl = (async () => {
      throw new TypeError(`network down while sending ${REFRESH_TOKEN}`);
    }) as typeof fetch;
    await assertFails(revokeAppleToken(credentials, REFRESH_TOKEN, fetchImpl), "unavailable");
  });

  it("does not call Apple when the key cannot be read", async () => {
    const { credentials } = await keys;
    const apple = fakeApple(() => new Response(null, { status: 200 }));
    await assertFails(
      revokeAppleToken({ ...credentials, privateKeyPem: "not a key" }, REFRESH_TOKEN, apple.fetchImpl),
      "invalid_client",
    );
    assert.equal(apple.calls.length, 0);
  });
});
