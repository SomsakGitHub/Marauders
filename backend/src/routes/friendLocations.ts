import { neon } from "@neondatabase/serverless";
import type { Env } from "../index";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" },
  });
}

function logDatabaseFailure(action: string, error: unknown): void {
  const { code, message } = (error ?? {}) as { code?: unknown; message?: unknown };
  console.error(`location sharing ${action} failed`, typeof code === "string" ? code : "no code", typeof message === "string" ? message : "no message");
}

/** A viewer with more mutual followers who share than this sees the most recently updated ones. */
export const FRIEND_LOCATION_LIMIT = 500;

type FriendRow = {
  handle: string;
  avatar_url: string | null;
  latitude: number | string;
  longitude: number | string;
  location_updated_at: string | Date | null;
};

/** Coordinates go out rounded to three decimals, about 100 m: the precision the app asks its iPhone for. */
function rounded(value: number | string): number {
  return Math.round(Number(value) * 1000) / 1000;
}

/**
 * The last known locations of the accounts `viewerID` follows that follow them back and share their location. Nothing
 * comes back unless the viewer shares too and has a location of their own on file: the switch works both ways, so
 * nobody sees others while staying unseen. `located` says whether the viewer's own location is on file yet.
 */
export async function handleFriendLocations(env: Env, viewerID: string): Promise<Response> {
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  try {
    const sql = neon(env.DATABASE_URL);
    const viewer = (await sql`
      SELECT shares_location, latitude IS NOT NULL AS located FROM app_users WHERE id = ${viewerID}::uuid`) as
      { shares_location: boolean; located: boolean }[];
    // The session token is checked without a database lookup, so it can outlive its account.
    if (!viewer.length) return json({ error: "account not found" }, 401);
    const located = viewer[0].located === true;
    if (viewer[0].shares_location !== true || !located) {
      return json({ sharing: viewer[0].shares_location === true, located, items: [] });
    }
    const rows = (await sql`
      SELECT u.handle, u.avatar_url, u.latitude, u.longitude, u.location_updated_at
      FROM user_follows mine
      JOIN user_follows theirs
        ON theirs.follower_user_id = mine.followed_user_id AND theirs.followed_user_id = mine.follower_user_id
      JOIN app_users u ON u.id = mine.followed_user_id
      WHERE mine.follower_user_id = ${viewerID}::uuid
        AND u.shares_location AND u.latitude IS NOT NULL AND u.longitude IS NOT NULL
      ORDER BY u.location_updated_at DESC NULLS LAST, u.handle
      LIMIT ${FRIEND_LOCATION_LIMIT}`) as FriendRow[];
    return json({
      sharing: true,
      located: true,
      items: rows.map(row => ({
        handle: row.handle,
        avatarURL: row.avatar_url,
        latitude: rounded(row.latitude),
        longitude: rounded(row.longitude),
        locationUpdatedAt: row.location_updated_at === null ? null : new Date(row.location_updated_at).toISOString(),
      })),
    });
  } catch (error) {
    logDatabaseFailure("read", error);
    return json({ error: "failed to load friend locations" }, 500);
  }
}

/**
 * Turns the viewer's location sharing on or off: `{ enabled: boolean }` → `{ sharesLocation }`. Turning it on forgets
 * the location on file, which the map stored before the viewer agreed to share: mutual followers see only where the
 * viewer is from then on (the app sends a fresh one at once).
 */
export async function handleLocationSharingUpdate(request: Request, env: Env, viewerID: string): Promise<Response> {
  let body: unknown;
  try { body = await request.json(); } catch { return json({ error: "invalid json body" }, 400); }
  const enabled = typeof body === "object" && body !== null ? (body as { enabled?: unknown }).enabled : undefined;
  if (typeof enabled !== "boolean") return json({ error: "enabled must be true or false" }, 400);
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  try {
    const sql = neon(env.DATABASE_URL);
    // Every expression reads the row as it was, so `NOT shares_location` means "was off".
    const rows = (await sql`
      UPDATE app_users SET
        latitude = CASE WHEN ${enabled} AND NOT shares_location THEN NULL ELSE latitude END,
        longitude = CASE WHEN ${enabled} AND NOT shares_location THEN NULL ELSE longitude END,
        location_updated_at = CASE WHEN ${enabled} AND NOT shares_location THEN NULL ELSE location_updated_at END,
        shares_location = ${enabled}
      WHERE id = ${viewerID}::uuid RETURNING shares_location`) as { shares_location: boolean }[];
    if (!rows.length) return json({ error: "account not found" }, 401);
    return json({ sharesLocation: rows[0].shares_location === true });
  } catch (error) {
    logDatabaseFailure("update", error);
    return json({ error: "failed to save location sharing" }, 500);
  }
}
