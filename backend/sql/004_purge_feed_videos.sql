-- One-time: remove every row from the feed (does not delete R2 files by itself).
-- Prefer: node scripts/purge-videos.mjs  (DB + R2)

DELETE FROM feed_videos; -- NOSONAR: removing every row is the whole point, and db:migrate never runs this file
