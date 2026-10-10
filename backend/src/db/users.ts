import { neon } from "@neondatabase/serverless";

type UserRow = { id: string };

export async function upsertUserByAppleSub(
  databaseUrl: string,
  appleSub: string,
): Promise<string> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    INSERT INTO app_users (apple_sub)
    VALUES (${appleSub})
    ON CONFLICT (apple_sub) DO UPDATE SET apple_sub = EXCLUDED.apple_sub
    RETURNING id
  `) as UserRow[];

  const row = rows[0];
  if (!row?.id) {
    throw new Error("user upsert failed");
  }
  return row.id;
}
