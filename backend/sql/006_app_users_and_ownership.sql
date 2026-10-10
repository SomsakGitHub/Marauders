-- Apple Sign In users and clip ownership (upload requires owner_user_id).

CREATE TABLE IF NOT EXISTS app_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    apple_sub VARCHAR(512) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT app_users_apple_sub_nonempty CHECK (char_length(apple_sub) >= 1),
    CONSTRAINT app_users_apple_sub_max_len CHECK (char_length(apple_sub) <= 512)
);

CREATE UNIQUE INDEX IF NOT EXISTS app_users_apple_sub_uidx ON app_users (apple_sub);

ALTER TABLE feed_videos
    ADD COLUMN IF NOT EXISTS owner_user_id UUID REFERENCES app_users (id);

CREATE INDEX IF NOT EXISTS feed_videos_owner_user_id_idx
    ON feed_videos (owner_user_id);
