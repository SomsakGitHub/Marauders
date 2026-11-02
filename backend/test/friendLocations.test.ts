import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { SignJWT } from "jose";

import worker from "../src/index";
import { FRIEND_LOCATION_LIMIT, handleFriendLocations } from "../src/routes/friendLocations";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests; none of them is a real secret.
const JWT_SECRET = "friend-locations-test-signing-secret-0123456789";
const VIEWER = "11111111-1111-4111-8111-111111111111";

const env = { DATABASE_URL: "postgres://fake.invalid/test", JWT_SIGNING_SECRET: JWT_SECRET } as never;

async function tokenFor(userId: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setExpirationTime("1h")
    .sign(new TextEncoder().encode(JWT_SECRET));
}

async function call(method: string, path: string, token: string | null = null, body?: string): Promise<Response> {
  const headers: Record<string, string> = token ? { Authorization: `Bearer ${token}` } : {};
  return worker.fetch(new Request(`https://api.test${path}`, { method, headers, body }), env);
}

type Script = {
  viewerRows?: unknown[];
  friendRows?: unknown[];
  updateRows?: unknown[];
  failWith?: Error;
  rateCount?: number;
};

/** Answers each statement the routes run, told apart by their SQL text. */
function script(s: Script = {}): void {
  respondWith((query) => {
    if (/rate_limit_counters/.test(query.text)) return [{ count: s.rateCount ?? 1 }];
    if (s.failWith) throw s.failWith;
    if (/UPDATE app_users SET/.test(query.text)) return s.updateRows ?? [{ shares_location: true }];
    if (/SELECT shares_location, latitude IS NOT NULL AS located FROM app_users/.test(query.text)) {
      return s.viewerRows ?? [{ shares_location: true, located: true }];
    }
    if (/FROM user_follows mine/.test(query.text)) return s.friendRows ?? [];
    throw new Error(`unexpected statement: ${query.text}`);
  });
}

function statement(pattern: RegExp) {
  return queries.find((query) => pattern.test(query.text));
}

const folded = (text: string) => text.replace(/\s+/g, " ");

function friendRow(overrides: Record<string, unknown> = {}) {
  return {
    handle: "@alice", avatar_url: "https://media.test/a.jpg", latitude: 13.75, longitude: 100.5,
    location_updated_at: "2026-11-01T10:00:00.000Z", ...overrides,
  };
}

describe("GET /v1/users/me/friend-locations", () => {
  beforeEach(() => resetFakeNeon());

  it("lists where the mutual followers who share are, newest first", async () => {
    script({ friendRows: [friendRow(), friendRow({ handle: "@bob", avatar_url: null, latitude: "-33.86", longitude: "151.2", location_updated_at: null })] });
    const res = await call("GET", "/v1/users/me/friend-locations", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.deepEqual(await res.json(), {
      sharing: true,
      located: true,
      items: [
        { handle: "@alice", avatarURL: "https://media.test/a.jpg", latitude: 13.75, longitude: 100.5, locationUpdatedAt: "2026-11-01T10:00:00.000Z" },
        { handle: "@bob", avatarURL: null, latitude: -33.86, longitude: 151.2, locationUpdatedAt: null },
      ],
    });
  });

  it("rounds coordinates to about 100 m", async () => {
    script({ friendRows: [friendRow({ latitude: 13.75678, longitude: "100.50149" })] });
    const body = (await (await call("GET", "/v1/users/me/friend-locations", await tokenFor(VIEWER))).json()) as
      { items: { latitude: number; longitude: number }[] };
    assert.deepEqual(body.items.map(i => [i.latitude, i.longitude]), [[13.757, 100.501]]);
  });

  it("asks only for accounts that follow the viewer back and share, and never for anyone's id", async () => {
    script({ friendRows: [] });
    await call("GET", "/v1/users/me/friend-locations", await tokenFor(VIEWER));
    const friends = statement(/FROM user_follows mine/);
    assert.ok(friends);
    const text = folded(friends.text);
    // Mutual: the viewer follows them and they follow the viewer.
    assert.match(text, /JOIN user_follows theirs ON theirs\.follower_user_id = mine\.followed_user_id AND theirs\.followed_user_id = mine\.follower_user_id/);
    assert.match(text, /WHERE mine\.follower_user_id = \?::uuid/);
    assert.match(text, /AND u\.shares_location AND u\.latitude IS NOT NULL AND u\.longitude IS NOT NULL/);
    assert.match(text, /ORDER BY u\.location_updated_at DESC NULLS LAST, u\.handle LIMIT \?/);
    assert.deepEqual(friends.values, [VIEWER, FRIEND_LOCATION_LIMIT]);
    assert.doesNotMatch(text, /SELECT[^]*\bu\.id\b[^]*FROM/, "no account id is sent back");
  });

  it("shows nothing to a viewer who does not share, and does not even look", async () => {
    script({ viewerRows: [{ shares_location: false, located: true }] });
    const res = await call("GET", "/v1/users/me/friend-locations", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { sharing: false, located: true, items: [] });
    assert.equal(statement(/FROM user_follows mine/), undefined);
    assert.deepEqual(statement(/AS located FROM app_users/)?.values, [VIEWER]);
  });

  // Sharing works both ways: a viewer whose own location is not on file yet (or who never sends one) sees nobody.
  it("shows nothing to a viewer who shares but has no location of their own yet", async () => {
    script({ viewerRows: [{ shares_location: true, located: false }] });
    const res = await call("GET", "/v1/users/me/friend-locations", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { sharing: true, located: false, items: [] });
    assert.equal(statement(/FROM user_follows mine/), undefined);
  });

  it("answers 401 when the token outlived its account", async () => {
    script({ viewerRows: [] });
    const res = await call("GET", "/v1/users/me/friend-locations", await tokenFor(VIEWER));
    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: "account not found" });
  });

  it("needs a signed-in viewer", async () => {
    script();
    assert.equal((await call("GET", "/v1/users/me/friend-locations")).status, 401);
    assert.equal((await call("GET", "/v1/users/me/friend-locations", "not-a-token")).status, 401);
    assert.equal(queries.length, 0);
  });

  it("hides the database's message on a failure", async (t) => {
    t.mock.method(console, "error", () => {});
    script({ failWith: Object.assign(new Error("secret-detail"), { code: "57P01" }) });
    const res = await call("GET", "/v1/users/me/friend-locations", await tokenFor(VIEWER));
    assert.equal(res.status, 500);
    assert.doesNotMatch(await res.text(), /secret-detail/);
  });

  it("answers 503 and asks nothing when the database is not configured", async () => {
    script();
    assert.equal((await handleFriendLocations({} as never, VIEWER)).status, 503);
    assert.equal(queries.length, 0);
  });
});

describe("PUT /v1/users/me/location-sharing", () => {
  beforeEach(() => resetFakeNeon());

  for (const enabled of [true, false]) {
    it(`turns sharing ${enabled ? "on" : "off"} and answers what was stored`, async () => {
      script({ updateRows: [{ shares_location: enabled }] });
      const res = await call("PUT", "/v1/users/me/location-sharing", await tokenFor(VIEWER), JSON.stringify({ enabled }));
      assert.equal(res.status, 200);
      assert.deepEqual(await res.json(), { sharesLocation: enabled });
      const update = statement(/UPDATE app_users SET/);
      assert.deepEqual(update?.values, [enabled, enabled, enabled, enabled, VIEWER]);
      const text = folded(update!.text);
      // Turning it on forgets a location stored before the viewer agreed; turning it off keeps it, unseen.
      for (const column of ["latitude", "longitude", "location_updated_at"]) {
        assert.match(text, new RegExp(`${column} = CASE WHEN \\? AND NOT shares_location THEN NULL ELSE ${column} END`), column);
      }
      assert.match(text, /shares_location = \? WHERE id = \?::uuid RETURNING shares_location/);
    });
  }

  it("refuses anything but a JSON boolean", async () => {
    script();
    const token = await tokenFor(VIEWER);
    for (const body of ["not json", "{}", '{"enabled":"true"}', '{"enabled":1}', '{"enabled":null}', "true", "[]"]) {
      assert.equal((await call("PUT", "/v1/users/me/location-sharing", token, body)).status, 400, body);
    }
    assert.equal(statement(/UPDATE app_users/), undefined);
  });

  it("answers 401 when the token outlived its account", async () => {
    script({ updateRows: [] });
    const res = await call("PUT", "/v1/users/me/location-sharing", await tokenFor(VIEWER), '{"enabled":true}');
    assert.equal(res.status, 401);
  });

  it("needs a signed-in viewer", async () => {
    script();
    assert.equal((await call("PUT", "/v1/users/me/location-sharing", null, '{"enabled":true}')).status, 401);
    assert.equal(queries.length, 0);
  });

  it("limits changes per viewer", async () => {
    script({ rateCount: 21 });
    const res = await call("PUT", "/v1/users/me/location-sharing", await tokenFor(VIEWER), '{"enabled":true}');
    assert.equal(res.status, 429);
    assert.ok(statement(/rate_limit_counters/)?.values.includes(`location-sharing:${VIEWER}`));
    assert.equal(statement(/UPDATE app_users/), undefined);
  });

  it("is not a sharing change for any other verb", async () => {
    script();
    const token = await tokenFor(VIEWER);
    assert.equal((await call("POST", "/v1/users/me/location-sharing", token, '{"enabled":true}')).status, 405);
    assert.equal(statement(/UPDATE app_users/), undefined);
  });
});

describe("POST /v1/users/me/location", () => {
  beforeEach(() => resetFakeNeon());

  function answer(sharesLocation: boolean) {
    respondWith((query) => {
      if (/UPDATE app_users\s+SET latitude/.test(query.text)) return [{ id: VIEWER, shares_location: sharesLocation }];
      throw new Error(`unexpected statement: ${query.text}`);
    });
  }

  const update = () => statement(/UPDATE app_users\s+SET latitude/)!;

  it("stores a location sent while the app is open whether or not the viewer shares", async () => {
    answer(false);
    const res = await call("POST", "/v1/users/me/location", await tokenFor(VIEWER), '{"latitude":13.75,"longitude":100.5}');
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { latitude: 13.75, longitude: 100.5, sharesLocation: false });
    assert.deepEqual(update().values, [false, 13.75, false, 100.5, false, VIEWER]);
  });

  it("keeps the old location when one sent while closed comes from a viewer who no longer shares", async () => {
    answer(false);
    const body = '{"latitude":13.75,"longitude":100.5,"whileClosed":true}';
    const res = await call("POST", "/v1/users/me/location", await tokenFor(VIEWER), body);
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as { sharesLocation: boolean }).sharesLocation, false);
    assert.deepEqual(update().values, [true, 13.75, true, 100.5, true, VIEWER]);
    const text = folded(update().text);
    for (const [column, fresh] of [["latitude", "\\?"], ["longitude", "\\?"], ["location_updated_at", "now\\(\\)"]]) {
      assert.match(text, new RegExp(`${column} = CASE WHEN \\? AND NOT shares_location THEN ${column} ELSE ${fresh} END`), column);
    }
    assert.match(text, /RETURNING id, shares_location/);
  });

  it("says when a viewer sharing while closed still shares", async () => {
    answer(true);
    const body = '{"latitude":13.75,"longitude":100.5,"whileClosed":true}';
    const res = await call("POST", "/v1/users/me/location", await tokenFor(VIEWER), body);
    assert.equal(((await res.json()) as { sharesLocation: boolean }).sharesLocation, true);
  });

  it("takes only a JSON true as sent while closed", async () => {
    const token = await tokenFor(VIEWER);
    for (const whileClosed of ['"true"', "1", "null", "false"]) {
      resetFakeNeon();
      answer(true);
      const body = `{"latitude":13.75,"longitude":100.5,"whileClosed":${whileClosed}}`;
      assert.equal((await call("POST", "/v1/users/me/location", token, body)).status, 200, whileClosed);
      assert.equal(update().values[0], false, whileClosed);
    }
  });

  it("needs a signed-in viewer", async () => {
    answer(true);
    assert.equal((await call("POST", "/v1/users/me/location", null, '{"latitude":1,"longitude":2}')).status, 401);
    assert.equal(queries.length, 0);
  });
});

describe("GET /v1/users/me sharing flag", () => {
  beforeEach(() => resetFakeNeon());

  it("tells the viewer whether they share their location", async () => {
    respondWith((query) => {
      if (/WHERE u\.id = \?::uuid/.test(query.text)) {
        return [{
          id: VIEWER, handle: "@viewer", country: "TH", avatar_url: null, latitude: null, longitude: null,
          location_updated_at: null, video_count: 0, follower_count: 0, following_count: 0, shares_location: true,
        }];
      }
      return [];
    });
    const res = await call("GET", "/v1/users/me", await tokenFor(VIEWER));
    assert.equal(res.status, 200);
    assert.equal(((await res.json()) as { sharesLocation: boolean }).sharesLocation, true);
    assert.match(folded(statement(/WHERE u\.id = \?::uuid/)!.text), /u\.shares_location FROM app_users u/);
  });
});
