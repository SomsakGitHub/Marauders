import { neon } from "@neondatabase/serverless";
import { assertHttpsStreamUrl } from "../validation";

export type FeedRow = {
  id: string;
  stream_url: string;
  author_name: string;
  caption: string;
  music_title: string;
};

export type FeedItemJson = {
  id: string;
  streamURL: string;
  authorName: string;
  caption: string;
  musicTitle: string;
};

export async function listFeedVideos(
  databaseUrl: string,
  limit: number,
  cursor: string | null,
): Promise<FeedItemJson[]> {
  const sql = neon(databaseUrl);

  const rows = (cursor
    ? await sql`
        SELECT id, stream_url, author_name, caption, music_title
        FROM feed_videos
        WHERE (sort_order, created_at, id) < (
          SELECT sort_order, created_at, id FROM feed_videos WHERE id = ${cursor}::uuid
        )
        ORDER BY sort_order DESC, created_at DESC, id DESC
        LIMIT ${limit}
      `
    : await sql`
        SELECT id, stream_url, author_name, caption, music_title
        FROM feed_videos
        ORDER BY sort_order DESC, created_at DESC, id DESC
        LIMIT ${limit}
      `) as FeedRow[];

  return rows.map((row) => {
    assertHttpsStreamUrl(row.stream_url);
    return {
      id: row.id,
      streamURL: row.stream_url,
      authorName: row.author_name,
      caption: row.caption,
      musicTitle: row.music_title,
    };
  });
}
