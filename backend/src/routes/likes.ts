import { neon } from "@neondatabase/serverless";
import type { Env } from "../index";
import { parseVideoId } from "../validation";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" },
  });
}

type LikeRow = { video_exists: number; like_count: number };

function logDatabaseFailure(action: string, error: unknown): void {
  const { code, message } = (error ?? {}) as { code?: unknown; message?: unknown };
  console.error(`likes ${action} failed`, typeof code === "string" ? code : "no code", typeof message === "string" ? message : "no message");
}

/**
 * PUT likes the clip as `userID`, DELETE takes the like back. Both are idempotent and answer the viewer's state and the
 * clip's count after the change, so the app can show the server's number instead of its own guess.
 */
export async function handleLikeChange(env: Env, rawVideoID: string, userID: string, liked: boolean): Promise<Response> {
  let videoID: string;
  try { videoID = parseVideoId(rawVideoID).toLowerCase(); } catch { return json({ error: "invalid video id" }, 400); }
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  try {
    const sql = neon(env.DATABASE_URL);
    // The outer SELECT reads the snapshot from before the statement, so it does not see the row the CTE inserted or
    // still sees the one it deleted; the CTE's own count corrects for that.
    const rows = (liked
      ? await sql`
          WITH v AS (SELECT id FROM feed_videos WHERE id = ${videoID}::uuid),
          changed AS (
            INSERT INTO video_likes (video_id, user_id) SELECT id, ${userID}::uuid FROM v
            ON CONFLICT (video_id, user_id) DO NOTHING RETURNING 1)
          SELECT (SELECT count(*) FROM v)::int AS video_exists,
            ((SELECT count(*) FROM video_likes WHERE video_id = ${videoID}::uuid) + (SELECT count(*) FROM changed))::int AS like_count`
      : await sql`
          WITH v AS (SELECT id FROM feed_videos WHERE id = ${videoID}::uuid),
          changed AS (
            DELETE FROM video_likes WHERE video_id = ${videoID}::uuid AND user_id = ${userID}::uuid RETURNING 1)
          SELECT (SELECT count(*) FROM v)::int AS video_exists,
            ((SELECT count(*) FROM video_likes WHERE video_id = ${videoID}::uuid) - (SELECT count(*) FROM changed))::int AS like_count`
    ) as LikeRow[];
    if (!rows.length || !rows[0].video_exists) return json({ error: "video not found" }, 404);
    return json({ liked, likeCount: Number(rows[0].like_count) });
  } catch (error) {
    const { code, constraint } = (error ?? {}) as { code?: unknown; constraint?: unknown };
    // The session token is checked without a database lookup, so it can outlive its account; the clip can also be
    // removed between the lookup and the insert. Neither succeeds on a retry.
    if (code === "23503" && constraint === "video_likes_user_id_fkey") return json({ error: "account not found" }, 401);
    if (code === "23503" && constraint === "video_likes_video_id_fkey") return json({ error: "video not found" }, 404);
    logDatabaseFailure(liked ? "like" : "unlike", error);
    return json({ error: "failed to save like" }, 500);
  }
}

/** The ids among `videoIDs` that `userID` likes. */
export async function likedVideoIDs(databaseUrl: string, userID: string, videoIDs: string[]): Promise<Set<string>> {
  if (!videoIDs.length) return new Set();
  const sql = neon(databaseUrl);
  const rows = (await sql`
    SELECT video_id FROM video_likes WHERE user_id = ${userID}::uuid AND video_id = ANY(${videoIDs}::uuid[])`) as { video_id: string }[];
  return new Set(rows.map(row => row.video_id.toLowerCase()));
}
