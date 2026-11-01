-- Likes on a clip: one row per viewer who likes it. The primary key keeps a viewer to one like per clip and serves the
-- per-clip count. Rows go with the clip or the viewer (ON DELETE CASCADE).

CREATE TABLE IF NOT EXISTS video_likes (
    video_id UUID NOT NULL REFERENCES feed_videos (id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES app_users (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (video_id, user_id)
);

-- "Which of these clips does this viewer like" for the feed.
CREATE INDEX IF NOT EXISTS video_likes_user_idx ON video_likes (user_id, video_id);
