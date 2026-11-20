import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import { exportPKCS8, generateKeyPair } from "jose";

import type { Env } from "../src/index";
import { MAX_CLIPS_PER_DELETION, handleAccountDelete } from "../src/routes/deleteAccount";
import { FeedValidationError, parseAccountDeletionBody } from "../src/validation";
import { FakeBucket } from "./fakes/bucket";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret. The key pair is generated fresh on every run.
const USER = "11111111-1111-4111-8111-111111111111";
const DATABASE_URL = "postgres://fake.invalid/test";
const CODE = "code-single-use-from-apple";
const ACCESS_TOKEN = "access-token-secret-aaa";
const REFRESH_TOKEN = "refresh-token-secret-bbb";
// The fake identity-token verifier answers "apple:<token>", so this token confirms the account whose apple_sub is APPLE_SUB.
const ID_TOKEN = "idtoken-secret-ccc";
const APPLE_SUB = `apple:${ID_TOKEN}`;
// An identity token that names another person, and one the verifier refuses; both contain ID_TOKEN so a leak of either is seen.
const OTHER_ID_TOKEN = `${ID_TOKEN}-of-someone-else`;
const REFUSED_ID_TOKEN = `invalid-${ID_TOKEN}`;

/** A well-formed lowercase uuid from a number. */
const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const media = (key: string) => `https://api.test/v1/media/${key}`;

const key = (async () => {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  return await exportPKCS8(privateKey);
})();

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const tokens = (override: Record<string, unknown> = {}) =>
  json(200, {
    access_token: ACCESS_TOKEN,
    token_type: "Bearer",
    expires_in: 3600,
    refresh_token: REFRESH_TOKEN,
    id_token: ID_TOKEN,
    ...override,
  });

/** Every bucket delete lands in the shared journal, so a test can say what happened in which order. */
class JournalBucket extends FakeBucket {
  constructor(private readonly journal: string[]) {
    super();
  }

  override async delete(keys: string | string[]): Promise<void> {
    this.journal.push("r2:delete");
    return await super.delete(keys);
  }
}

type Clip = { id: string; streamUrl: string };
type AppleCall = { url: string; form: URLSearchParams };

/** One person's deletion request, with a fake database, bucket and Apple, and a journal of what each of them was asked. */
class Scene {
  events: string[] = [];
  bucket = new JournalBucket(this.events);
  appleCalls: AppleCall[] = [];
  waitUntilPromises: Promise<unknown>[] = [];
  user: { appleSub: string; avatarUrl: string | null } | null = { appleSub: APPLE_SUB, avatarUrl: null };
  clips: Clip[] = [];
  /** How many of the next delete statements fail. */
  databaseFailures = 0;
  tokenAnswer: () => Response = () => tokens();
  revokeAnswer: () => Response = () => new Response(null, { status: 200 });
  appleUnreachable = false;
  /** While set, every call to Apple waits for it before answering (to show who is made to wait). */
  appleHold: Promise<void> | null = null;
  env: Record<string, unknown>;
  pem: string;

  private constructor(pem: string) {
    this.pem = pem;
    this.env = {
      DATABASE_URL,
      VIDEOS: this.bucket,
      JWT_SIGNING_SECRET: "j".repeat(40),
      ENVIRONMENT: "test",
      APPLE_CLIENT_ID: "com.example.test",
      APPLE_TEAM_ID: "TEAM123456",
      APPLE_KEY_ID: "KEY1234567",
      APPLE_PRIVATE_KEY: pem,
    };
    resetFakeNeon();
    respondWith((query) => {
      // The one statement holds both table names, so it is told apart first.
      if (/WITH deleted_clips/.test(query.text)) {
        this.events.push("db:delete");
        if (this.databaseFailures > 0) {
          this.databaseFailures -= 1;
          throw new Error("connection reset");
        }
        return [];
      }
      if (/FROM feed_videos/.test(query.text)) {
        return this.clips.slice(0, Number(query.values[1])).map((clip) => ({ id: clip.id, stream_url: clip.streamUrl }));
      }
      if (/FROM app_users/.test(query.text)) {
        return this.user
          ? [{ id: USER, apple_sub: this.user.appleSub, avatar_url: this.user.avatarUrl }]
          : [];
      }
      throw new Error(`unexpected query: ${query.text}`);
    });
  }

  static async create(): Promise<Scene> {
    return new Scene(await key);
  }

  /** An account with an avatar and one plain clip, each with its files in the bucket. */
  static async withAccount(): Promise<Scene> {
    const scene = await Scene.create();
    scene.user = { appleSub: APPLE_SUB, avatarUrl: media(`avatars/${uuid(900)}.jpg`) };
    scene.clips = [{ id: uuid(101), streamUrl: media(`videos/${uuid(201)}.mp4`) }];
    scene.putObjects(`avatars/${uuid(900)}.jpg`, `videos/${uuid(201)}.mp4`, `translations/${uuid(101)}/th/abc.m4a`);
    return scene;
  }

  putObjects(...keys: string[]): void {
    for (const objectKey of keys) {
      this.bucket.objects.set(objectKey, "bytes");
    }
  }

  private fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    this.appleCalls.push({ url, form: new URLSearchParams(String(init?.body ?? "")) });
    const step = url.endsWith("/auth/token") ? "token" : url.endsWith("/auth/revoke") ? "revoke" : "other";
    assert.notEqual(step, "other", `unexpected request to ${url}`);
    this.events.push(`apple:${step}`);
    if (this.appleHold) {
      await this.appleHold;
    }
    if (this.appleUnreachable) {
      throw new TypeError("network down");
    }
    return step === "token" ? this.tokenAnswer() : this.revokeAnswer();
  }) as typeof fetch;

  private ctx = {
    waitUntil: (promise: Promise<unknown>) => {
      this.waitUntilPromises.push(promise);
    },
    passThroughOnException() {},
  } as unknown as ExecutionContext;

  /** DELETE /v1/users/me with `body` sent as JSON. */
  async call(body: unknown = { authorizationCode: CODE }): Promise<Response> {
    return await this.send(JSON.stringify(body));
  }

  /** The same request with `text` as it is, JSON or not. */
  async send(text: string): Promise<Response> {
    const request = new Request("https://api.test/v1/users/me", {
      method: "DELETE",
      headers: { "content-type": "application/json" },
      body: text,
    });
    return await handleAccountDelete(request, this.env as unknown as Env, this.ctx, USER, this.fetchImpl);
  }

  deleteStatements(): number {
    return queries.filter((query) => /WITH deleted_clips/.test(query.text)).length;
  }

  exchangeCall(): AppleCall | undefined {
    return this.appleCalls.find((call) => call.url.endsWith("/auth/token"));
  }

  revokeCall(): AppleCall | undefined {
    return this.appleCalls.find((call) => call.url.endsWith("/auth/revoke"));
  }
}

// What a person must never get back, and what no log line or query may carry.
async function secrets(scene: Scene): Promise<string[]> {
  return [CODE, ACCESS_TOKEN, REFRESH_TOKEN, ID_TOKEN, scene.pem.split("\n")[1].slice(0, 40)];
}

// console is captured for every test, so a leak into a log line is seen.
let logged: string[] = [];
const originalConsole = { ...console };
beforeEach(() => {
  logged = [];
  for (const level of ["log", "info", "warn", "error", "debug"] as const) {
    console[level] = (...args: unknown[]) => {
      logged.push(args.map(String).join(" "));
    };
  }
});
afterEach(() => {
  Object.assign(console, originalConsole);
});

async function assertNothingLeaked(scene: Scene, response: Response, text: string): Promise<void> {
  const seen = [text, ...logged, JSON.stringify(queries.map((query) => query.values)), JSON.stringify([...response.headers])];
  for (const secret of await secrets(scene)) {
    for (const haystack of seen) {
      assert.ok(!haystack.includes(secret), `"${secret.slice(0, 10)}…" appears in ${haystack.slice(0, 80)}`);
    }
  }
}

describe("parseAccountDeletionBody", () => {
  it("reads a code of 1 to 1,024 characters as it is", () => {
    assert.deepEqual(parseAccountDeletionBody({ authorizationCode: "x" }), { authorizationCode: "x" });
    const longest = "c".repeat(1024);
    assert.deepEqual(parseAccountDeletionBody({ authorizationCode: longest }), { authorizationCode: longest });
  });

  it("reads an absent code as null", () => {
    assert.deepEqual(parseAccountDeletionBody({}), { authorizationCode: null });
  });

  const refused: Array<[string, unknown]> = [
    ["a body that is not an object", "just text"],
    ["a body that is null", null],
    ["a body that is a number", 5],
    ["a body that is an array", []],
    ["a code that is a number", { authorizationCode: 12345 }],
    ["a code that is null", { authorizationCode: null }],
    ["a code that is empty", { authorizationCode: "" }],
    ["a code of 1,025 characters", { authorizationCode: "c".repeat(1025) }],
  ];
  for (const [name, body] of refused) {
    it(`refuses ${name} with a 400 that does not repeat it`, () => {
      assert.throws(
        () => parseAccountDeletionBody(body),
        (error: unknown) => {
          assert.ok(error instanceof FeedValidationError);
          assert.equal(error.status, 400);
          assert.ok(!error.message.includes("c".repeat(20)));
          return true;
        },
      );
    });
  }
});

describe("handleAccountDelete", () => {
  describe("the body (RF 4)", () => {
    const bad: Array<[string, unknown]> = [
      ["a body that is not an object", "just text"],
      ["a body that is null", null],
      ["a code that is a number", { authorizationCode: 12345 }],
      ["a code that is null", { authorizationCode: null }],
      ["a code that is empty", { authorizationCode: "" }],
      ["a code of 1,025 characters", { authorizationCode: "c".repeat(1025) }],
    ];
    for (const [name, body] of bad) {
      it(`answers 400 for ${name} before anything else happens`, async () => {
        const scene = await Scene.withAccount();

        const response = await scene.call(body);

        assert.equal(response.status, 400);
        assert.deepEqual(scene.events, []);
        assert.equal(queries.length, 0);
      });
    }

    it("answers 400 for a body that is not JSON, and for no body at all", async () => {
      for (const text of ["{not json", ""]) {
        const scene = await Scene.withAccount();

        const response = await scene.send(text);

        assert.equal(response.status, 400);
        assert.deepEqual(scene.events, []);
        assert.equal(queries.length, 0);
      }
    });
  });

  describe("an account that is already gone (RF 2)", () => {
    // A retry after a lost 204 comes with a fresh code: the person confirmed with Apple again, and because the first run revoked
    // the earlier grant, that confirmation made a new one. Nothing else would ever revoke it, so the handler asks Apple to,
    // best effort, after it has answered. It is never asked for the bucket or the delete statement.
    const settle = async (scene: Scene): Promise<void> => {
      await Promise.all(scene.waitUntilPromises);
    };

    it("answers 204 and deletes nothing: no bucket call and no delete statement", async () => {
      const scene = await Scene.withAccount();
      scene.user = null;

      const response = await scene.call();
      await settle(scene);

      assert.equal(response.status, 204);
      assert.equal(await response.text(), "");
      assert.equal(queries.length, 1);
      assert.match(queries[0].text, /FROM app_users/);
      assert.equal(scene.deleteStatements(), 0);
      assert.deepEqual(scene.bucket.calls, []);
    });

    it("revokes the grant the new confirmation made, once, with the code that came with the request", async () => {
      const scene = await Scene.withAccount();
      scene.user = null;

      const response = await scene.call();
      await settle(scene);

      assert.equal(response.status, 204);
      assert.deepEqual(scene.events, ["apple:token", "apple:revoke"]);
      assert.equal(scene.exchangeCall()?.form.get("code"), CODE);
      assert.equal(scene.revokeCall()?.form.get("token"), REFRESH_TOKEN);
      assert.equal(scene.waitUntilPromises.length, 1, "the revoke is given to waitUntil once");
      await assertNothingLeaked(scene, response, "");
    });

    it("does not make the person wait for Apple", async () => {
      const scene = await Scene.withAccount();
      scene.user = null;
      let release: () => void = () => {};
      scene.appleHold = new Promise<void>((resolve) => {
        release = resolve;
      });

      // Apple has not answered, and will not until `release` is called: the person has their 204 all the same. The race is
      // there so that a handler that does wait fails this test quickly instead of hanging it.
      let timer: ReturnType<typeof setTimeout> | undefined;
      const answered = await Promise.race([
        scene.call(),
        new Promise<null>((resolve) => {
          timer = setTimeout(() => resolve(null), 1000);
        }),
      ]);
      clearTimeout(timer);
      release();
      assert.ok(answered !== null, "the answer came while Apple had not answered");
      assert.equal(answered.status, 204);

      await settle(scene);
      assert.deepEqual(scene.events, ["apple:token", "apple:revoke"], "the revoke still happens after the response");
    });

    const refusals: Array<[string, (scene: Scene) => void]> = [
      [
        "Apple refuses the code",
        (scene) => {
          scene.tokenAnswer = () => json(400, { error: "invalid_grant", error_description: `code ${CODE} was used` });
        },
      ],
      [
        "Apple answers with a server error",
        (scene) => {
          scene.tokenAnswer = () => json(500, { error: "server_error" });
        },
      ],
      [
        "Apple answers without tokens",
        (scene) => {
          scene.tokenAnswer = () => json(200, { access_token: ACCESS_TOKEN });
        },
      ],
      [
        "Apple cannot be reached",
        (scene) => {
          scene.appleUnreachable = true;
        },
      ],
      [
        "Apple refuses the revoke",
        (scene) => {
          scene.revokeAnswer = () => json(400, { error: "invalid_request", error_description: REFRESH_TOKEN });
        },
      ],
    ];
    for (const [name, arrange] of refusals) {
      it(`still answers 204 when ${name}, and logs only the name of the step`, async () => {
        const scene = await Scene.withAccount();
        scene.user = null;
        arrange(scene);

        const response = await scene.call();
        await settle(scene); // the work given to waitUntil never rejects

        assert.equal(response.status, 204);
        assert.ok(scene.events.includes("apple:token"), "Apple was asked");
        assert.equal(scene.deleteStatements(), 0);
        assert.deepEqual(scene.bucket.calls, []);
        assert.ok(
          logged.some((line) => line.startsWith("account deletion: could not")),
          `a step name was logged: ${JSON.stringify(logged)}`,
        );
        await assertNothingLeaked(scene, response, "");
      });
    }

    it("asks Apple nothing when the request carries no code (a test account sends none)", async () => {
      const scene = await Scene.withAccount();
      scene.user = null;

      const response = await scene.call({});
      await settle(scene);

      assert.equal(response.status, 204);
      assert.deepEqual(scene.events, []);
      assert.equal(scene.waitUntilPromises.length, 0);
    });

    it("asks Apple nothing when the Apple secrets are not set", async () => {
      const scene = await Scene.withAccount();
      scene.user = null;
      delete scene.env.APPLE_PRIVATE_KEY;

      const response = await scene.call();
      await settle(scene);

      assert.equal(response.status, 204);
      assert.deepEqual(scene.events, []);
      assert.equal(scene.waitUntilPromises.length, 0);
    });
  });

  describe("the cap on clips", () => {
    const manyClips = (count: number): Clip[] =>
      Array.from({ length: count }, (_, index) => ({
        id: uuid(1000 + index),
        streamUrl: media(`videos/${uuid(2000 + index)}.mp4`),
      }));

    it("answers 409 with the limit when there are more clips than the cap, and does nothing", async () => {
      const scene = await Scene.withAccount();
      scene.clips = manyClips(MAX_CLIPS_PER_DELETION + 1);

      const response = await scene.call();

      assert.equal(response.status, 409);
      const body = (await response.json()) as { error: string; limit: number };
      assert.equal(body.limit, MAX_CLIPS_PER_DELETION);
      assert.equal(typeof body.error, "string");
      assert.deepEqual(scene.events, []);
      // One more than the cap is asked for, which is how the cap being passed is learned.
      const clipQuery = queries.find((query) => /FROM feed_videos/.test(query.text));
      assert.equal(clipQuery?.values[1], MAX_CLIPS_PER_DELETION + 1);
    });

    it("deletes an account with exactly the cap of clips", async () => {
      const scene = await Scene.withAccount();
      scene.clips = manyClips(MAX_CLIPS_PER_DELETION);

      const response = await scene.call();

      assert.equal(response.status, 204);
      assert.equal(scene.deleteStatements(), 1);
    });
  });

  describe("configuration", () => {
    it("answers 400 for an Apple account that sends no code", async () => {
      const scene = await Scene.withAccount();

      const response = await scene.call({});

      assert.equal(response.status, 400);
      assert.deepEqual(scene.events, []);
    });

    for (const name of ["APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY", "APPLE_CLIENT_ID"]) {
      it(`answers 503 and calls no one when ${name} is missing`, async () => {
        const scene = await Scene.withAccount();
        delete scene.env[name];

        const response = await scene.call();

        assert.equal(response.status, 503);
        assert.deepEqual(scene.events, []);
        assert.deepEqual(scene.appleCalls, []);
      });
    }

    it("answers 503 and does nothing when the bucket is not bound", async () => {
      const scene = await Scene.withAccount();
      delete scene.env.VIDEOS;

      const response = await scene.call();

      assert.equal(response.status, 503);
      assert.deepEqual(scene.events, []);
    });

    it("answers 503 without a query when the database is not configured", async () => {
      const scene = await Scene.withAccount();
      delete scene.env.DATABASE_URL;

      const response = await scene.call();

      assert.equal(response.status, 503);
      assert.equal(queries.length, 0);
      assert.deepEqual(scene.events, []);
    });

    for (const [name, failing] of [
      ["the person's row", /FROM app_users/],
      ["the clips", /FROM feed_videos/],
    ] as const) {
      it(`answers 500 and calls no one when reading ${name} fails`, async () => {
        const scene = await Scene.withAccount();
        const answer = scene.user;
        respondWith((query) => {
          if (failing.test(query.text)) {
            throw new Error("connection reset");
          }
          return answer ? [{ id: USER, apple_sub: answer.appleSub, avatar_url: answer.avatarUrl }] : [];
        });

        const response = await scene.call();

        assert.equal(response.status, 500);
        assert.deepEqual(scene.events, []);
      });
    }
  });

  describe("a successful deletion", () => {
    it("tells Apple first, then removes the files, then the rows, and answers 204 with no body", async () => {
      const scene = await Scene.withAccount();

      const response = await scene.call();

      assert.equal(response.status, 204);
      assert.equal(await response.text(), "");
      // The avatar, the dubbed audio of the clip and the clip's own file are three bucket deletes.
      assert.deepEqual(scene.events, [
        "apple:token",
        "apple:revoke",
        "r2:delete",
        "r2:delete",
        "r2:delete",
        "db:delete",
      ]);
      assert.equal(scene.exchangeCall()?.form.get("code"), CODE);
      assert.equal(scene.exchangeCall()?.form.get("client_id"), "com.example.test");
      assert.equal(scene.revokeCall()?.form.get("token"), REFRESH_TOKEN);
      assert.equal(scene.revokeCall()?.form.get("token_type_hint"), "refresh_token");
      const statement = queries.find((query) => /WITH deleted_clips/.test(query.text));
      assert.deepEqual(statement?.values, [USER, USER]);
      assert.equal(scene.bucket.objects.size, 0);
    });

    it("hands the whole run to waitUntil as one promise that resolves to the very response it returned (RF)", async () => {
      const scene = await Scene.withAccount();

      const response = await scene.call();

      assert.equal(scene.waitUntilPromises.length, 1);
      assert.equal(await scene.waitUntilPromises[0], response);
    });

    it("does the same for an answer that is a refusal, and that promise never rejects", async () => {
      const scene = await Scene.withAccount();
      scene.tokenAnswer = () => tokens({ id_token: OTHER_ID_TOKEN });

      const response = await scene.call();

      assert.equal(response.status, 403);
      assert.equal(scene.waitUntilPromises.length, 1);
      assert.equal(await scene.waitUntilPromises[0], response);
    });
  });

  describe("an account with no clips and no avatar (RF 1)", () => {
    it("answers 204 with no bucket call and exactly one delete statement", async () => {
      const scene = await Scene.create();

      const response = await scene.call();

      assert.equal(response.status, 204);
      assert.deepEqual(scene.events, ["apple:token", "apple:revoke", "db:delete"]);
      assert.deepEqual(scene.bucket.calls, []);
      assert.equal(scene.deleteStatements(), 1);
    });
  });

  describe("when Apple does not confirm", () => {
    const failures: Array<{
      name: string;
      status: number;
      events: string[];
      arrange: (scene: Scene) => void;
    }> = [
      {
        name: "an identity token of another account",
        status: 403,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => tokens({ id_token: OTHER_ID_TOKEN });
        },
      },
      {
        name: "a code Apple refuses (invalid_grant)",
        status: 400,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => json(400, { error: "invalid_grant" });
        },
      },
      {
        name: "a client Apple refuses (invalid_client)",
        status: 503,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => json(400, { error: "invalid_client" });
        },
      },
      {
        name: "an exchange that answers 500",
        status: 502,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => new Response("", { status: 500 });
        },
      },
      {
        name: "a request that cannot be sent",
        status: 502,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.appleUnreachable = true;
        },
      },
      {
        name: "an exchange that answers 200 without a refresh token (RF 4)",
        status: 502,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => tokens({ refresh_token: undefined });
        },
      },
      {
        name: "an exchange that answers 200 without an identity token (RF 4)",
        status: 502,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => tokens({ id_token: undefined });
        },
      },
      {
        name: "an exchange that answers 200 with something that is not JSON (RF 4)",
        status: 502,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => new Response("<html>not json</html>", { status: 200 });
        },
      },
      {
        name: "an identity token the verifier refuses",
        status: 502,
        events: ["apple:token"],
        arrange: (scene) => {
          scene.tokenAnswer = () => tokens({ id_token: REFUSED_ID_TOKEN });
        },
      },
      {
        name: "a revoke that answers 500",
        status: 502,
        events: ["apple:token", "apple:revoke"],
        arrange: (scene) => {
          scene.revokeAnswer = () => new Response("", { status: 500 });
        },
      },
      {
        name: "a revoke that Apple refuses (invalid_client)",
        status: 503,
        events: ["apple:token", "apple:revoke"],
        arrange: (scene) => {
          scene.revokeAnswer = () => json(400, { error: "invalid_client" });
        },
      },
      {
        // The code was accepted a moment ago, so a refused revoke is Apple's trouble, never "the code is wrong".
        name: "a revoke that Apple refuses with invalid_grant",
        status: 502,
        events: ["apple:token", "apple:revoke"],
        arrange: (scene) => {
          scene.revokeAnswer = () => json(400, { error: "invalid_grant" });
        },
      },
    ];

    for (const failure of failures) {
      it(`answers ${failure.status} for ${failure.name} and removes nothing`, async () => {
        const scene = await Scene.withAccount();
        failure.arrange(scene);

        const response = await scene.call();

        assert.equal(response.status, failure.status);
        assert.deepEqual(scene.events, failure.events);
        assert.equal(scene.bucket.objects.size, 3, "every file is still there");
        assert.equal(scene.deleteStatements(), 0);
        // One log line, the step that failed; the leak tests below rely on the log being captured.
        assert.equal(logged.length, 1);
        assert.match(logged[0], /^account deletion: could not /);
      });
    }
  });

  describe("a test account made by the debug sign-in", () => {
    it("is deleted without Apple, with no Apple setting present, and the code is ignored", async () => {
      for (const body of [{}, { authorizationCode: "ignored" }]) {
        const scene = await Scene.withAccount();
        scene.user = { appleSub: "dev:ui", avatarUrl: scene.user?.avatarUrl ?? null };
        for (const name of ["APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY", "APPLE_CLIENT_ID"]) {
          delete scene.env[name];
        }

        const response = await scene.call(body);

        assert.equal(response.status, 204);
        assert.deepEqual(scene.appleCalls, []);
        assert.ok(!scene.events.some((event) => event.startsWith("apple:")));
        assert.equal(scene.events.at(-1), "db:delete");
        assert.equal(scene.bucket.objects.size, 0);
        assert.equal(scene.waitUntilPromises.length, 1);
      }
    });
  });

  describe("when the bucket fails", () => {
    it("answers 502 after Apple was told, keeps the rows, and a second try with a new code finishes", async () => {
      const scene = await Scene.withAccount();
      scene.bucket.failNext("delete", 3);

      const first = await scene.call();

      assert.equal(first.status, 502);
      assert.deepEqual(scene.events, ["apple:token", "apple:revoke", "r2:delete", "r2:delete", "r2:delete"]);
      assert.equal(scene.deleteStatements(), 0);

      scene.events.length = 0;
      const second = await scene.call({ authorizationCode: "a-new-code" });

      assert.equal(second.status, 204);
      assert.equal(scene.exchangeCall()?.form.get("code"), CODE, "the first exchange used the first code");
      assert.equal(scene.appleCalls.at(-2)?.form.get("code"), "a-new-code");
      assert.equal(scene.events.at(-1), "db:delete");
      assert.equal(scene.bucket.objects.size, 0);
    });
  });

  describe("when the database fails at the end", () => {
    it("tries the statement again and answers 204 when the second try works", async () => {
      const scene = await Scene.withAccount();
      scene.databaseFailures = 1;

      const response = await scene.call();

      assert.equal(response.status, 204);
      assert.equal(scene.deleteStatements(), 2);
    });

    it("answers 500 after three failed tries", async () => {
      const scene = await Scene.withAccount();
      scene.databaseFailures = 3;

      const response = await scene.call();

      assert.equal(response.status, 500);
      assert.equal(scene.deleteStatements(), 3);
    });
  });

  describe("which objects are removed", () => {
    it("removes a plain clip, an HLS clip, the avatar and all dubbed audio, and leaves the neighbour's files", async () => {
      const scene = await Scene.create();
      const plainFile = uuid(301);
      const hlsFile = uuid(302);
      const neighbourFile = uuid(303);
      scene.user = { appleSub: APPLE_SUB, avatarUrl: media(`avatars/${uuid(900)}.jpg`) };
      // The clip's row id and the uuid in its file name differ on purpose: files are found by the name in the stream URL.
      scene.clips = [
        { id: uuid(101), streamUrl: media(`videos/${plainFile}.mp4`) },
        { id: uuid(102), streamUrl: media(`videos/${hlsFile}/master.m3u8`) },
      ];
      scene.putObjects(
        `avatars/${uuid(900)}.jpg`,
        `videos/${plainFile}.mp4`,
        `videos/${hlsFile}/master.m3u8`,
        `videos/${hlsFile}/seg000.ts`,
        `videos/${hlsFile}/seg001.ts`,
        `videos/${hlsFile}/seg002.ts`,
        `videos/${hlsFile}.mov`,
        `translations/${uuid(101)}/th/a.m4a`,
        `translations/${uuid(101)}/th/a.txt`,
        `translations/${uuid(102)}/en/b.m4a`,
        // someone else's
        `avatars/${uuid(901)}.jpg`,
        `videos/${neighbourFile}.mp4`,
        `videos/${neighbourFile}/master.m3u8`,
        `translations/${uuid(103)}/th/c.m4a`,
      );
      scene.bucket.pageSize = 2;

      const response = await scene.call();

      assert.equal(response.status, 204);
      assert.deepEqual([...scene.bucket.objects.keys()].sort(), [
        `avatars/${uuid(901)}.jpg`,
        `translations/${uuid(103)}/th/c.m4a`,
        `videos/${neighbourFile}.mp4`,
        `videos/${neighbourFile}/master.m3u8`,
      ]);
    });

    it("makes no bucket call of its own for a stream URL that is not ours, and deletes a hand-made name as exactly that key", async () => {
      const scene = await Scene.create();
      scene.clips = [
        { id: uuid(101), streamUrl: "https://elsewhere.test/v.mp4" },
        { id: uuid(102), streamUrl: media("videos/demo.mp4") },
      ];
      scene.putObjects("videos/demo.mp4", "videos/demo.mp4.bak", "videos/other.mp4");

      const response = await scene.call();

      assert.equal(response.status, 204);
      assert.deepEqual([...scene.bucket.objects.keys()].sort(), ["videos/demo.mp4.bak", "videos/other.mp4"]);
      const listed = scene.bucket.calls.filter((call) => call.op === "list").map((call) => (call.arg as { prefix: string }).prefix);
      assert.ok(listed.every((prefix) => prefix.startsWith("translations/")), `only dubbed audio is listed: ${listed}`);
      assert.equal(scene.deleteStatements(), 1);
    });
  });

  describe("what leaves the Worker", () => {
    const scenes: Array<[string, (scene: Scene) => void]> = [
      ["a success", () => {}],
      ["an identity token of another account", (scene) => (scene.tokenAnswer = () => tokens({ id_token: OTHER_ID_TOKEN }))],
      ["a code Apple refuses", (scene) => (scene.tokenAnswer = () => json(400, { error: "invalid_grant", error_description: `bad ${CODE}` }))],
      ["a client Apple refuses", (scene) => (scene.tokenAnswer = () => json(400, { error: "invalid_client", error_description: ACCESS_TOKEN }))],
      ["an exchange without a refresh token", (scene) => (scene.tokenAnswer = () => tokens({ refresh_token: undefined }))],
      ["an identity token the verifier refuses", (scene) => (scene.tokenAnswer = () => tokens({ id_token: REFUSED_ID_TOKEN }))],
      ["a revoke that fails", (scene) => (scene.revokeAnswer = () => json(500, { error: "server_error", token: REFRESH_TOKEN }))],
      ["a request that cannot be sent", (scene) => (scene.appleUnreachable = true)],
      ["a bucket that fails", (scene) => scene.bucket.failNext("delete", 3)],
      ["a database that fails", (scene) => (scene.databaseFailures = 3)],
    ];
    for (const [name, arrange] of scenes) {
      it(`never shows the code, a token or the key: ${name}`, async () => {
        const scene = await Scene.withAccount();
        arrange(scene);

        const response = await scene.call();
        const text = await response.text();

        await assertNothingLeaked(scene, response, text);
      });
    }

    it("never shows them for a code that is refused before Apple is asked", async () => {
      const scene = await Scene.withAccount();

      const response = await scene.call({ authorizationCode: "c".repeat(1025) });
      const text = await response.text();

      assert.equal(response.status, 400);
      await assertNothingLeaked(scene, response, text);
    });
  });
});
