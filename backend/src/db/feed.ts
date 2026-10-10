import { neon } from "@neondatabase/serverless";
import { assertHttpsStreamUrl } from "../validation";

type FeedRow = {
  id: string;
  stream_url: string;
  latitude: number | null;
  longitude: number | null;
};

export type FeedItemJson = {
  id: string;
  streamURL: string;
  latitude: number | null;
  longitude: number | null;
};

const UPLOAD_AUTHOR_NAME = "@marauders";
const UPLOAD_CAPTION = " ";
const UPLOAD_MUSIC_TITLE = "—";

export async function listFeedVideos(
  databaseUrl: string,
  limit: number,
  cursor: string | null,
): Promise<FeedItemJson[]> {
  const sql = neon(databaseUrl);

  const rows = (cursor
    ? await sql`
        SELECT id, stream_url, latitude, longitude
        FROM feed_videos
        WHERE (sort_order, created_at, id) < (
          SELECT sort_order, created_at, id FROM feed_videos WHERE id = ${cursor}::uuid
        )
        ORDER BY sort_order DESC, created_at DESC, id DESC
        LIMIT ${limit}
      `
    : await sql`
        SELECT id, stream_url, latitude, longitude
        FROM feed_videos
        ORDER BY sort_order DESC, created_at DESC, id DESC
        LIMIT ${limit}
      `) as FeedRow[];

  return rows.map((row) => {
    assertHttpsStreamUrl(row.stream_url);
    return {
      id: row.id,
      streamURL: row.stream_url,
      latitude: row.latitude,
      longitude: row.longitude,
    };
  });
}

export async function insertFeedVideo(
  databaseUrl: string,
  streamUrl: string,
  latitude: number,
  longitude: number,
  ownerUserId: string,
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
      ${UPLOAD_CAPTION},
      ${UPLOAD_MUSIC_TITLE},
      (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM feed_videos),
      ${latitude},
      ${longitude},
      ${ownerUserId}::uuid
    )
    RETURNING id, stream_url, latitude, longitude
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
  };
}
