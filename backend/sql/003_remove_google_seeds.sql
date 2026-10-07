-- Google sample bucket now returns 403 for many clients — remove broken seed rows.
-- Your uploads on marauders-api (R2) are kept.

DELETE FROM feed_videos
WHERE stream_url LIKE '%storage.googleapis.com%';
