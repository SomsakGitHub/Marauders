-- Who follows whom: one row per follower and account they follow. The primary key keeps a follower to one row per
-- account and serves "how many accounts does this viewer follow" and "does this viewer follow these accounts". Nobody
-- follows themself. Rows go with either account (ON DELETE CASCADE).

CREATE TABLE IF NOT EXISTS user_follows (
    follower_user_id UUID NOT NULL REFERENCES app_users (id) ON DELETE CASCADE,
    followed_user_id UUID NOT NULL REFERENCES app_users (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_user_id, followed_user_id),
    CONSTRAINT user_follows_not_self CHECK (follower_user_id <> followed_user_id)
);

-- "How many follow this account" for profiles, newest first for a list of its followers.
CREATE INDEX IF NOT EXISTS user_follows_followed_idx ON user_follows (followed_user_id, created_at DESC, follower_user_id);
