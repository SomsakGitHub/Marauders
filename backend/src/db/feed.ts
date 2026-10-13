import { neon } from "@neondatabase/serverless";
import { assertHttpsStreamUrl } from "../validation";

type FeedRow = {
  id: string;
  stream_url: string;
  latitude: number | null;
  longitude: number | null;
  country: string | null;
  author_name?: string | null;
  caption?: string | null;
  music_title?: string | null;
};

export type FeedItemJson = {
  id: string;
  streamURL: string;
  latitude: number | null;
  longitude: number | null;
  country: string | null;
  authorName: string | null;
  caption: string | null;
  musicTitle: string | null;
};

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
        SELECT v.id, v.stream_url, v.latitude, v.longitude, v.author_name, v.caption, v.music_title, u.country
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
        SELECT v.id, v.stream_url, v.latitude, v.longitude, v.author_name, v.caption, v.music_title, u.country
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
    SELECT v.id, v.stream_url, v.latitude, v.longitude, v.author_name, v.caption, v.music_title, u.country
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
      caption: row.caption ?? null,
      musicTitle: row.music_title ?? null,
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
  musicTitle: string = "",
): Promise<FeedItemJson> {
  assertHttpsStreamUrl(streamUrl);

  const sql = neon(databaseUrl);
  const rows = (await sql`
    INSERT INTO feed_videos (
      stream_url,
      author_name,
      caption,
      music_title,
      sort_order,
      latitude,
      longitude,
      owner_user_id
    )
    VALUES (
      ${streamUrl},
      ${UPLOAD_AUTHOR_NAME},
      ${caption},
      ${musicTitle},
      (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM feed_videos),
      ${latitude},
      ${longitude},
      ${ownerUserId}::uuid
    )
    RETURNING id, stream_url, latitude, longitude, author_name, caption, music_title
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
    caption: row.caption ?? null,
    musicTitle: row.music_title ?? null,
  };
}
