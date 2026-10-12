import { neon } from "@neondatabase/serverless";

type UserRow = { id: string };

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
