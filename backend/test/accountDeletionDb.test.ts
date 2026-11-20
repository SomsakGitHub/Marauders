import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { deleteUserAndClips, getUserForDeletion, listClipsForDeletion } from "../src/db/accountDeletion";
import { queries, resetFakeNeon, respondWith } from "./fakes/neon";

// Throwaway values made up for the tests.
const DATABASE_URL = "postgres://fake.invalid/test";
const USER = "11111111-1111-4111-8111-111111111111";
const CLIP = "22222222-2222-4222-8222-222222222222";

describe("account deletion statements", () => {
  beforeEach(() => resetFakeNeon());

  describe("getUserForDeletion", () => {
    it("reads the person's row with one statement and names the columns the route needs", async () => {
      respondWith(() => [{ id: USER, apple_sub: "001234.abc", avatar_url: "https://api.test/v1/media/avatars/a.jpg" }]);

      const user = await getUserForDeletion(DATABASE_URL, USER);

      assert.equal(queries.length, 1);
      assert.match(queries[0].text, /FROM app_users/);
      assert.match(queries[0].text, /WHERE id = \?::uuid/);
      assert.deepEqual(queries[0].values, [USER]);
      assert.deepEqual(user, {
        id: USER,
        appleSub: "001234.abc",
        avatarUrl: "https://api.test/v1/media/avatars/a.jpg",
      });
    });

    it("keeps a missing avatar as null", async () => {
      respondWith(() => [{ id: USER, apple_sub: "dev:someone", avatar_url: null }]);

      assert.equal((await getUserForDeletion(DATABASE_URL, USER))?.avatarUrl, null);
    });

    it("returns null when there is no such row", async () => {
      respondWith(() => []);

      assert.equal(await getUserForDeletion(DATABASE_URL, USER), null);
    });
  });

  describe("listClipsForDeletion", () => {
    it("reads at most the limit of the person's clips with one statement", async () => {
      respondWith(() => [{ id: CLIP, stream_url: "https://api.test/v1/media/videos/a.mp4" }]);

      const clips = await listClipsForDeletion(DATABASE_URL, USER, 16);

      assert.equal(queries.length, 1);
      assert.match(queries[0].text, /FROM feed_videos/);
      assert.match(queries[0].text, /owner_user_id = \?::uuid/);
      assert.match(queries[0].text, /LIMIT \?/);
      assert.deepEqual(queries[0].values, [USER, 16]);
      assert.deepEqual(clips, [{ id: CLIP, streamUrl: "https://api.test/v1/media/videos/a.mp4" }]);
    });

    it("returns an empty list for a person with no clips", async () => {
      respondWith(() => []);

      assert.deepEqual(await listClipsForDeletion(DATABASE_URL, USER, 16), []);
    });
  });

  describe("deleteUserAndClips", () => {
    it("deletes the clips and the person in exactly one statement", async () => {
      await deleteUserAndClips(DATABASE_URL, USER);

      assert.equal(queries.length, 1);
      assert.match(
        queries[0].text,
        /WITH deleted_clips AS \(\s*DELETE FROM feed_videos WHERE owner_user_id = \?::uuid RETURNING id\s*\)\s*DELETE FROM app_users WHERE id = \?::uuid/,
      );
      assert.deepEqual(queries[0].values, [USER, USER]);
    });

    it("lets a database failure through", async () => {
      respondWith(() => {
        throw new Error("connection reset");
      });

      await assert.rejects(deleteUserAndClips(DATABASE_URL, USER), /connection reset/);
    });
  });
});
