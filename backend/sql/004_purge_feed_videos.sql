-- One-time: remove every row from the feed (does not delete R2 files by itself).
-- Prefer: node scripts/purge-videos.mjs  (DB + R2)

DELETE FROM feed_videos;
