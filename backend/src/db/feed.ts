import { neon } from "@neondatabase/serverless";
import { assertHttpsStreamUrl } from "../validation";

type FeedRow = {
  id: string;
  stream_url: string;
  latitude: number | null;
  longitude: number | null;
  country: string | null;
  author_name?: string | null;
  avatar_url?: string | null;
  caption?: string | null;
  audio_assessment?: Record<string, unknown> | null;
};

export type FeedItemJson = {
  id: string;
  streamURL: string;
  latitude: number | null;
  longitude: number | null;
  country: string | null;
  authorName: string | null;
  authorAvatarURL: string | null;
  caption: string | null;
  audioAssessment: Record<string, unknown> | null;
};

/** Fallback author name when an owner row is missing (should not happen post-auth). */
const UPLOAD_AUTHOR_NAME = "@marauders";

export async function listFeedVideos(
  databaseUrl: string,
  limit: number,
  cursor: string | null,
  country: string | null = null,
): Promise<FeedItemJson[]> {
  const sql = neon(databaseUrl);

  const rows = (cursor
    ? await sql`
        SELECT v.id, v.stream_url, v.latitude, v.longitude, COALESCE(u.handle, v.author_name) AS author_name, u.avatar_url, v.caption, v.audio_assessment, u.country
        FROM feed_videos v
        LEFT JOIN app_users u ON u.id = v.owner_user_id
        WHERE (${country}::text IS NULL OR u.country = ${country})
          AND (v.sort_order, v.created_at, v.id) < (
            SELECT sort_order, created_at, id FROM feed_videos WHERE id = ${cursor}::uuid
          )
        ORDER BY v.sort_order DESC, v.created_at DESC, v.id DESC
        LIMIT ${limit}
      `
    : await sql`
        SELECT v.id, v.stream_url, v.latitude, v.longitude, COALESCE(u.handle, v.author_name) AS author_name, u.avatar_url, v.caption, v.audio_assessment, u.country
        FROM feed_videos v
        LEFT JOIN app_users u ON u.id = v.owner_user_id
        WHERE (${country}::text IS NULL OR u.country = ${country})
        ORDER BY v.sort_order DESC, v.created_at DESC, v.id DESC
        LIMIT ${limit}
      `) as FeedRow[];

  return mapFeedRows(rows);
}

export async function listUserFeedVideos(
  databaseUrl: string,
  userId: string,
  limit: number,
): Promise<FeedItemJson[]> {
  const sql = neon(databaseUrl);

  const rows = (await sql`
    SELECT v.id, v.stream_url, v.latitude, v.longitude, COALESCE(u.handle, v.author_name) AS author_name, u.avatar_url, v.caption, v.audio_assessment, u.country
    FROM feed_videos v
    LEFT JOIN app_users u ON u.id = v.owner_user_id
    WHERE v.owner_user_id = ${userId}::uuid
    ORDER BY v.sort_order DESC, v.created_at DESC, v.id DESC
    LIMIT ${limit}
  `) as FeedRow[];

  return mapFeedRows(rows);
}

/** Deletes a video owned by `ownerUserId`, returning its stream URL (or null if not found/not owned). */
export async function deleteFeedVideo(
  databaseUrl: string,
  videoId: string,
  ownerUserId: string,
): Promise<string | null> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    DELETE FROM feed_videos
    WHERE id = ${videoId}::uuid AND owner_user_id = ${ownerUserId}::uuid
    RETURNING stream_url
  `) as { stream_url: string }[];

  return rows[0]?.stream_url ?? null;
}

function mapFeedRows(rows: FeedRow[]): FeedItemJson[] {  return rows.map((row) => {
    assertHttpsStreamUrl(row.stream_url);
    return {
      id: row.id,
      streamURL: row.stream_url,
      latitude: row.latitude,
      longitude: row.longitude,
      country: row.country,
      authorName: row.author_name ?? null,
      authorAvatarURL: row.avatar_url ?? null,
      caption: row.caption ?? null,
    audioAssessment: row.audio_assessment ?? null,
    };
  });
}

export async function insertFeedVideo(
  databaseUrl: string,
  streamUrl: string,
  latitude: number,
  longitude: number,
  ownerUserId: string,
  caption: string = "",
  audioAssessment: Record<string, unknown> | null = null,
): Promise<FeedItemJson> {
  assertHttpsStreamUrl(streamUrl);

  const sql = neon(databaseUrl);
  const rows = (await sql`
    INSERT INTO feed_videos (
      stream_url,
      author_name,
      caption,
      sort_order,
      latitude,
      longitude,
      owner_user_id,
      audio_assessment
    )
    VALUES (
      ${streamUrl},
      COALESCE((SELECT handle FROM app_users WHERE id = ${ownerUserId}::uuid), ${UPLOAD_AUTHOR_NAME}),
      ${caption},
      (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM feed_videos),
      ${latitude},
      ${longitude},
      ${ownerUserId}::uuid,
      ${audioAssessment === null ? null : JSON.stringify(audioAssessment)}::jsonb
    )
    RETURNING id, stream_url, latitude, longitude, author_name,
      (SELECT avatar_url FROM app_users WHERE id = ${ownerUserId}::uuid) AS avatar_url,
      caption, audio_assessment
  `) as FeedRow[];

  const row = rows[0];
  if (!row) {
    throw new Error("insert failed");
  }

  return {
    id: row.id,
    streamURL: row.stream_url,
    latitude: row.latitude,
    longitude: row.longitude,
    country: null,
    authorName: row.author_name ?? null,
    authorAvatarURL: row.avatar_url ?? null,
    caption: row.caption ?? null,
    audioAssessment: row.audio_assessment ?? null,
  };
}
