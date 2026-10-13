-- Profile avatar (TikTok-style). Stores the public URL of the user's avatar in R2.
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE app_users DROP CONSTRAINT IF EXISTS app_users_avatar_url_https;
ALTER TABLE app_users ADD CONSTRAINT app_users_avatar_url_https
    CHECK (avatar_url IS NULL OR avatar_url ~ '^https://');
