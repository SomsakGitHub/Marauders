-- Backfill feed_videos.author_name with the owner's current @handle so the
-- column is not stale. Reads already prefer app_users.handle via COALESCE.
UPDATE feed_videos v
SET author_name = u.handle
FROM app_users u
WHERE u.id = v.owner_user_id
  AND v.author_name IS DISTINCT FROM u.handle;
