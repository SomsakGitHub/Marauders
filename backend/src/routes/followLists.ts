import { neon, type NeonQueryFunction } from "@neondatabase/serverless";
import type { Env } from "../index";
import { FeedValidationError, parseFeedLimit, parseHandle } from "../validation";

export type FollowListKind = "followers" | "following";

/**
 * Where a page stopped: the last row's follow time as exact text (microseconds kept, which a JavaScript `Date` would
 * lose) and that account's handle. It holds values, not a pointer to a row, so it keeps working when that row is gone,
 * which is the common case (the viewer unfollows the last row they loaded and scrolls on).
 */
export type FollowListCursor = { followedAt: string; handle: string };

const CURSOR_MAX_LENGTH = 200;
const CURSOR_ALPHABET_RE = /^[A-Za-z0-9_-]+$/;
const CURSOR_TEXT_RE = /^(([1-9]\d{3})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d\.\d{6}Z)\|(.+)$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "private, no-store", "x-content-type-options": "nosniff" },
  });
}

function logDatabaseFailure(error: unknown): void {
  const { code, message } = (error ?? {}) as { code?: unknown; message?: unknown };
  console.error("follows list failed", typeof code === "string" ? code : "no code", typeof message === "string" ? message : "no message");
}

/** `<followedAt>|<handle>` as base64url without padding. Both parts are ASCII. */
export function encodeFollowListCursor(cursor: FollowListCursor): string {
  return btoa(`${cursor.followedAt}|${cursor.handle}`).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** null for no cursor. Anything that is not a cursor this Worker could have made is a 400 `invalid cursor`. */
export function decodeFollowListCursor(raw: string | null): FollowListCursor | null {
  if (raw === null || raw === "") return null;
  if (raw.length > CURSOR_MAX_LENGTH || !CURSOR_ALPHABET_RE.test(raw)) throw new FeedValidationError("invalid cursor");
  let text: string;
  try {
    const base64 = raw.replace(/-/g, "+").replace(/_/g, "/");
    text = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
  } catch {
    throw new FeedValidationError("invalid cursor");
  }
  const match = CURSOR_TEXT_RE.exec(text);
  if (!match) throw new FeedValidationError("invalid cursor");
  const [, followedAt, year, month, day, rawHandle] = match;
  // The pattern fixes the shape; the round trip through Date refuses a day the calendar does not have (02-30, month 00).
  const date = new Date(Date.UTC(Number(year), Number(month) - 1, Number(day)));
  if (date.getUTCFullYear() !== Number(year) || date.getUTCMonth() !== Number(month) - 1 || date.getUTCDate() !== Number(day)) {
    throw new FeedValidationError("invalid cursor");
  }
  let handle: string;
  try { handle = parseHandle(rawHandle); } catch { throw new FeedValidationError("invalid cursor"); }
  return { followedAt, handle };
}

type PageRow = {
  handle: string;
  avatar_url: string | null;
  followed_at: string;
  followed_by_viewer: boolean | null;
  is_viewer: boolean | null;
};

/**
 * One page after `cursor`, newest follow first, then the other account's id ascending: exactly the order of
 * user_follows_followed_idx, so the followers page needs no sort. Reads `limit + 1` rows; the extra one only decides
 * whether there is a next page. The cursor's account is found by its handle; when that no longer resolves, the
 * tie-break falls back to the smallest uuid, so the rows with the cursor's timestamp are read again (the app drops the
 * repeats by handle) and none is skipped.
 */
async function readPage(
  sql: NeonQueryFunction<false, false>,
  kind: FollowListKind,
  viewerID: string,
  ownerID: string,
  cursor: FollowListCursor | null,
  limit: number,
): Promise<PageRow[]> {
  const after = cursor?.followedAt ?? null;
  const afterHandle = cursor?.handle ?? null;
  return (kind === "followers"
    ? await sql`
        SELECT u.handle, u.avatar_url,
          to_char(f.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS followed_at,
          EXISTS (SELECT 1 FROM user_follows mine
            WHERE mine.follower_user_id = ${viewerID}::uuid AND mine.followed_user_id = u.id) AS followed_by_viewer,
          (u.id = ${viewerID}::uuid) AS is_viewer
        FROM user_follows f JOIN app_users u ON u.id = f.follower_user_id
        WHERE f.followed_user_id = ${ownerID}::uuid
          AND (${after}::timestamptz IS NULL OR f.created_at < ${after}::timestamptz
            OR (f.created_at = ${after}::timestamptz AND f.follower_user_id > COALESCE(
              (SELECT id FROM app_users WHERE handle = ${afterHandle}), '00000000-0000-0000-0000-000000000000'::uuid)))
        ORDER BY f.created_at DESC, f.follower_user_id ASC
        LIMIT ${limit + 1}`
    : await sql`
        SELECT u.handle, u.avatar_url,
          to_char(f.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS followed_at,
          EXISTS (SELECT 1 FROM user_follows mine
            WHERE mine.follower_user_id = ${viewerID}::uuid AND mine.followed_user_id = u.id) AS followed_by_viewer,
          (u.id = ${viewerID}::uuid) AS is_viewer
        FROM user_follows f JOIN app_users u ON u.id = f.followed_user_id
        WHERE f.follower_user_id = ${ownerID}::uuid
          AND (${after}::timestamptz IS NULL OR f.created_at < ${after}::timestamptz
            OR (f.created_at = ${after}::timestamptz AND f.followed_user_id > COALESCE(
              (SELECT id FROM app_users WHERE handle = ${afterHandle}), '00000000-0000-0000-0000-000000000000'::uuid)))
        ORDER BY f.created_at DESC, f.followed_user_id ASC
        LIMIT ${limit + 1}`
  ) as PageRow[];
}

/**
 * GET /v1/users/{handle}/followers and /following: the accounts that follow the profile, or that it follows, newest
 * first, for a signed-in `viewerID`. The caller has already checked the session and the rate limit. No account id is
 * ever put in the answer; the viewer's own row says `isViewer` and every row says whether the viewer follows it.
 */
export async function handleFollowList(
  request: Request,
  env: Env,
  rawHandle: string,
  kind: FollowListKind,
  viewerID: string,
): Promise<Response> {
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  let handle: string;
  try { handle = parseHandle(rawHandle); } catch { return json({ error: "invalid handle" }, 400); }
  let limit: number;
  let cursor: FollowListCursor | null;
  try {
    const params = new URL(request.url).searchParams;
    limit = parseFeedLimit(params.get("limit"));
    cursor = decodeFollowListCursor(params.get("cursor"));
  } catch (error) {
    if (error instanceof FeedValidationError) return json({ error: error.message }, 400);
    throw error;
  }
  try {
    const sql = neon(env.DATABASE_URL);
    const owners = (await sql`SELECT id FROM app_users WHERE handle = ${handle}`) as { id: string }[];
    const ownerID = owners[0]?.id;
    if (!ownerID) return json({ error: "profile not found" }, 404);
    const rows = await readPage(sql, kind, viewerID, ownerID, cursor, limit);
    const items = rows.slice(0, limit).map(row => ({
      handle: row.handle,
      avatarURL: row.avatar_url,
      followedByViewer: row.followed_by_viewer === true,
      isViewer: row.is_viewer === true,
    }));
    const last = rows.length > limit ? rows[limit - 1] : null;
    const nextCursor = last ? encodeFollowListCursor({ followedAt: last.followed_at, handle: last.handle }) : null;
    return json({ items, nextCursor });
  } catch (error) {
    logDatabaseFailure(error);
    return json({ error: "failed to load list" }, 500);
  }
}
