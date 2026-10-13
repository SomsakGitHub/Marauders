import { neon } from "@neondatabase/serverless";

type UserRow = { id: string };

type UserProfileRow = {
  id: string;
  handle: string;
  country: string | null;
  avatar_url: string | null;
  latitude: number | null;
  longitude: number | null;
  location_updated_at: string | null;
  video_count: number;
};

export type UserProfileJson = {
  id: string;
  handle: string;
  country: string | null;
  avatarURL: string | null;
  latitude: number | null;
  longitude: number | null;
  locationUpdatedAt: string | null;
  videoCount: number;
};

export type PublicAccountJson = {
  userId: string;
  handle: string;
  country: string | null;
  avatarURL: string | null;
  videoCount: number;
};

export class HandleConflictError extends Error {
  constructor() {
    super("handle already taken");
    this.name = "HandleConflictError";
  }
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    (error as { code?: string }).code === "23505"
  );
}

function generateHandle(): string {
  const token = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
  return `@user_${token}`;
}

export async function upsertUserByAppleSub(
  databaseUrl: string,
  appleSub: string,
  country: string | null = null,
): Promise<string> {
  const sql = neon(databaseUrl);

  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      const rows = (await sql`
        INSERT INTO app_users (apple_sub, country, handle)
        VALUES (${appleSub}, ${country}, ${generateHandle()})
        ON CONFLICT (apple_sub) DO UPDATE SET
          country = COALESCE(EXCLUDED.country, app_users.country)
        RETURNING id
      `) as UserRow[];

      const row = rows[0];
      if (row?.id) {
        return row.id;
      }
      throw new Error("user upsert failed");
    } catch (error) {
      // A generated handle collided with an existing one — try another.
      if (isUniqueViolation(error) && attempt < 4) {
        continue;
      }
      throw error;
    }
  }

  throw new Error("user upsert failed");
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

export async function updateUserHandle(
  databaseUrl: string,
  userId: string,
  handle: string,
): Promise<string> {
  const sql = neon(databaseUrl);
  try {
    const rows = (await sql`
      UPDATE app_users
      SET handle = ${handle}
      WHERE id = ${userId}::uuid
      RETURNING handle
    `) as { handle: string }[];

    const row = rows[0];
    if (!row?.handle) {
      throw new Error("user not found");
    }
    return row.handle;
  } catch (error) {
    if (isUniqueViolation(error)) {
      throw new HandleConflictError();
    }
    throw error;
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
      u.handle,
      u.country,
      u.avatar_url,
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
    handle: row.handle,
    country: row.country,
    avatarURL: row.avatar_url,
    latitude: row.latitude,
    longitude: row.longitude,
    locationUpdatedAt: row.location_updated_at,
    videoCount: Number(row.video_count),
  };
}

export async function getPublicAccountByHandle(
  databaseUrl: string,
  handle: string,
): Promise<PublicAccountJson | null> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    SELECT
      u.id,
      u.handle,
      u.country,
      u.avatar_url,
      (SELECT COUNT(*) FROM feed_videos v WHERE v.owner_user_id = u.id) AS video_count
    FROM app_users u
    WHERE u.handle = ${handle}
  `) as {
    id: string;
    handle: string;
    country: string | null;
    avatar_url: string | null;
    video_count: number;
  }[];

  const row = rows[0];
  if (!row) {
    return null;
  }

  return {
    userId: row.id,
    handle: row.handle,
    country: row.country,
    avatarURL: row.avatar_url,
    videoCount: Number(row.video_count),
  };
}

/** Sets the avatar URL, returning the previous URL (for best-effort R2 cleanup). */
export async function setUserAvatar(
  databaseUrl: string,
  userId: string,
  avatarUrl: string,
): Promise<string | null> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    WITH prev AS (
      SELECT avatar_url FROM app_users WHERE id = ${userId}::uuid
    )
    UPDATE app_users
    SET avatar_url = ${avatarUrl}
    WHERE id = ${userId}::uuid
    RETURNING (SELECT avatar_url FROM prev) AS previous_avatar_url
  `) as { previous_avatar_url: string | null }[];

  const row = rows[0];
  if (!row) {
    throw new Error("user not found");
  }
  return row.previous_avatar_url ?? null;
}

/** Clears the avatar URL, returning the previous URL (for best-effort R2 cleanup). */
export async function clearUserAvatar(
  databaseUrl: string,
  userId: string,
): Promise<string | null> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    WITH prev AS (
      SELECT avatar_url FROM app_users WHERE id = ${userId}::uuid
    )
    UPDATE app_users
    SET avatar_url = NULL
    WHERE id = ${userId}::uuid
    RETURNING (SELECT avatar_url FROM prev) AS previous_avatar_url
  `) as { previous_avatar_url: string | null }[];

  const row = rows[0];
  if (!row) {
    throw new Error("user not found");
  }
  return row.previous_avatar_url ?? null;
}
