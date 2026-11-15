-- An upload key for a clip. The app sends one UUID with each upload and keeps it for every retry of that upload, so a retry
-- is answered with the clip that is already stored instead of making a second one. NULL for clips uploaded before this
-- column existed and for builds that send no key. The key is scoped to the account that sent it.

ALTER TABLE feed_videos ADD COLUMN IF NOT EXISTS upload_key UUID;

-- One stored clip per account and key. The index is partial, so clips without a key never meet it.
CREATE UNIQUE INDEX IF NOT EXISTS feed_videos_owner_upload_key_uidx
    ON feed_videos (owner_user_id, upload_key) WHERE upload_key IS NOT NULL;
