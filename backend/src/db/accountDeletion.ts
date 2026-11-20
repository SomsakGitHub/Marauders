import { neon } from "@neondatabase/serverless";

export type UserForDeletion = { id: string; appleSub: string; avatarUrl: string | null };
export type ClipForDeletion = { id: string; streamUrl: string };

/** The signed-in person's row, or null when it is already gone (a repeat of a deletion that finished). */
export async function getUserForDeletion(
  databaseUrl: string,
  userId: string,
): Promise<UserForDeletion | null> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    SELECT id, apple_sub, avatar_url
    FROM app_users
    WHERE id = ${userId}::uuid
  `) as Array<{ id: string; apple_sub: string; avatar_url: string | null }>;
  const row = rows[0];
  return row ? { id: row.id, appleSub: row.apple_sub, avatarUrl: row.avatar_url } : null;
}

/** At most `limit` of the person's clips (ask for one more than the cap to learn the cap was passed). */
export async function listClipsForDeletion(
  databaseUrl: string,
  userId: string,
  limit: number,
): Promise<ClipForDeletion[]> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    SELECT id, stream_url
    FROM feed_videos
    WHERE owner_user_id = ${userId}::uuid
    LIMIT ${limit}
  `) as Array<{ id: string; stream_url: string }>;
  return rows.map((row) => ({ id: row.id, streamUrl: row.stream_url }));
}

/**
 * Deletes the person's clips and then the person, in one statement so a failure leaves both or neither. feed_videos.owner_user_id
 * has no ON DELETE action, so the clips must go in the same statement; every other table that points at the person or at a clip
 * (comments, likes, follows, dubbed audio reports, refresh tokens) is ON DELETE CASCADE.
 */
export async function deleteUserAndClips(databaseUrl: string, userId: string): Promise<void> {
  const sql = neon(databaseUrl);
  await sql`
    WITH deleted_clips AS (
      DELETE FROM feed_videos WHERE owner_user_id = ${userId}::uuid RETURNING id
    )
    DELETE FROM app_users WHERE id = ${userId}::uuid
  `;
}
