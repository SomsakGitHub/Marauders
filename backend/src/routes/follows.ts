import { neon } from "@neondatabase/serverless";
import type { Env } from "../index";
import { parseHandle } from "../validation";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" },
  });
}

type FollowRow = { target_id: string | null; follower_count: number; viewer_following_count: number };

function logDatabaseFailure(action: string, error: unknown): void {
  const { code, message } = (error ?? {}) as { code?: unknown; message?: unknown };
  console.error(`follows ${action} failed`, typeof code === "string" ? code : "no code", typeof message === "string" ? message : "no message");
}

/**
 * PUT follows the account with `rawHandle` as `viewerID`, DELETE stops following it. Both are idempotent and answer the
 * viewer's state, the account's follower count and the viewer's own following count after the change, so the app can
 * show the server's numbers instead of its own guesses.
 */
export async function handleFollowChange(env: Env, rawHandle: string, viewerID: string, following: boolean): Promise<Response> {
  let handle: string;
  try { handle = parseHandle(rawHandle); } catch { return json({ error: "invalid handle" }, 400); }
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  try {
    const sql = neon(env.DATABASE_URL);
    // The outer SELECT reads the snapshot from before the statement, so it does not see the row the CTE inserted or
    // still sees the one it deleted; the CTE's own count corrects for that. Nothing is written for the viewer's own
    // handle, which is refused below.
    const rows = (following
      ? await sql`
          WITH target AS (SELECT id FROM app_users WHERE handle = ${handle}),
          changed AS (
            INSERT INTO user_follows (follower_user_id, followed_user_id)
            SELECT ${viewerID}::uuid, id FROM target WHERE id <> ${viewerID}::uuid
            ON CONFLICT (follower_user_id, followed_user_id) DO NOTHING RETURNING 1)
          SELECT (SELECT id FROM target) AS target_id,
            ((SELECT count(*) FROM user_follows WHERE followed_user_id = (SELECT id FROM target))
              + (SELECT count(*) FROM changed))::int AS follower_count,
            ((SELECT count(*) FROM user_follows WHERE follower_user_id = ${viewerID}::uuid)
              + (SELECT count(*) FROM changed))::int AS viewer_following_count`
      : await sql`
          WITH target AS (SELECT id FROM app_users WHERE handle = ${handle}),
          changed AS (
            DELETE FROM user_follows
            WHERE follower_user_id = ${viewerID}::uuid AND followed_user_id = (SELECT id FROM target) RETURNING 1)
          SELECT (SELECT id FROM target) AS target_id,
            ((SELECT count(*) FROM user_follows WHERE followed_user_id = (SELECT id FROM target))
              - (SELECT count(*) FROM changed))::int AS follower_count,
            ((SELECT count(*) FROM user_follows WHERE follower_user_id = ${viewerID}::uuid)
              - (SELECT count(*) FROM changed))::int AS viewer_following_count`
    ) as FollowRow[];
    const row = rows[0];
    if (!row?.target_id) return json({ error: "profile not found" }, 404);
    if (row.target_id.toLowerCase() === viewerID.toLowerCase()) return json({ error: "cannot follow yourself" }, 422);
    return json({
      following,
      followerCount: Number(row.follower_count),
      viewerFollowingCount: Number(row.viewer_following_count),
    });
  } catch (error) {
    const { code, constraint } = (error ?? {}) as { code?: unknown; constraint?: unknown };
    // The session token is checked without a database lookup, so it can outlive its account; the other account can
    // also be removed between the lookup and the insert. Neither succeeds on a retry.
    if (code === "23503" && constraint === "user_follows_follower_user_id_fkey") return json({ error: "account not found" }, 401);
    if (code === "23503" && constraint === "user_follows_followed_user_id_fkey") return json({ error: "profile not found" }, 404);
    logDatabaseFailure(following ? "follow" : "unfollow", error);
    return json({ error: "failed to save follow" }, 500);
  }
}

/**
 * What a clip's author is to the viewer: the viewer themself, or someone they follow. `authorFollowedByViewer` is null
 * for a clip without an owner account, which nobody can follow.
 */
export type AuthorRelation = { postedByViewer: boolean; authorFollowedByViewer: boolean | null };

/** For each of `videoIDs` (lowercased), whether `viewerID` posted the clip and whether they follow its author. */
export async function authorRelations(databaseUrl: string, viewerID: string, videoIDs: string[]): Promise<Map<string, AuthorRelation>> {
  if (!videoIDs.length) return new Map();
  const sql = neon(databaseUrl);
  const rows = (await sql`
    SELECT v.id AS video_id, COALESCE(v.owner_user_id = ${viewerID}::uuid, false) AS posted_by_viewer,
      CASE WHEN v.owner_user_id IS NULL THEN NULL ELSE EXISTS (SELECT 1 FROM user_follows f
        WHERE f.follower_user_id = ${viewerID}::uuid AND f.followed_user_id = v.owner_user_id) END AS author_followed
    FROM feed_videos v WHERE v.id = ANY(${videoIDs}::uuid[])`) as
    { video_id: string; posted_by_viewer: boolean | null; author_followed: boolean | null }[];
  return new Map(rows.map(row => [row.video_id.toLowerCase(), {
    postedByViewer: row.posted_by_viewer === true,
    authorFollowedByViewer: row.author_followed === null ? null : row.author_followed === true,
  }]));
}
