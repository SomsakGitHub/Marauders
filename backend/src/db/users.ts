import { neon } from "@neondatabase/serverless";

type UserRow = { id: string };

type UserProfileRow = {
  id: string;
  country: string | null;
  latitude: number | null;
  longitude: number | null;
  location_updated_at: string | null;
  video_count: number;
};

export type UserProfileJson = {
  id: string;
  country: string | null;
  latitude: number | null;
  longitude: number | null;
  locationUpdatedAt: string | null;
  videoCount: number;
};

export async function upsertUserByAppleSub(
  databaseUrl: string,
  appleSub: string,
  country: string | null = null,
): Promise<string> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    INSERT INTO app_users (apple_sub, country)
    VALUES (${appleSub}, ${country})
    ON CONFLICT (apple_sub) DO UPDATE SET
      country = COALESCE(EXCLUDED.country, app_users.country)
    RETURNING id
  `) as UserRow[];

  const row = rows[0];
  if (!row?.id) {
    throw new Error("user upsert failed");
  }
  return row.id;
}

export async function updateUserLocation(
  databaseUrl: string,
  userId: string,
  latitude: number,
  longitude: number,
): Promise<void> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    UPDATE app_users
    SET latitude = ${latitude},
        longitude = ${longitude},
        location_updated_at = now()
    WHERE id = ${userId}
    RETURNING id
  `) as UserRow[];

  if (!rows[0]?.id) {
    throw new Error("user not found");
  }
}

export async function getUserProfile(
  databaseUrl: string,
  userId: string,
): Promise<UserProfileJson | null> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    SELECT
      u.id,
      u.country,
      u.latitude,
      u.longitude,
      u.location_updated_at,
      (SELECT COUNT(*) FROM feed_videos v WHERE v.owner_user_id = u.id) AS video_count
    FROM app_users u
    WHERE u.id = ${userId}::uuid
  `) as UserProfileRow[];

  const row = rows[0];
  if (!row) {
    return null;
  }

  return {
    id: row.id,
    country: row.country,
    latitude: row.latitude,
    longitude: row.longitude,
    locationUpdatedAt: row.location_updated_at,
    videoCount: Number(row.video_count),
  };
}
