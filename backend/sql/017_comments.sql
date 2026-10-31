-- Comments on a clip. `language` is the base language the author's iPhone detected (one of the dubbing
-- languages) or NULL when unknown. Viewers translate on their own iPhone, so the server stores only the original.
-- Rows go with the clip or the author (ON DELETE CASCADE).

CREATE TABLE IF NOT EXISTS comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    video_id UUID NOT NULL REFERENCES feed_videos (id) ON DELETE CASCADE,
    author_user_id UUID NOT NULL REFERENCES app_users (id) ON DELETE CASCADE,
    body TEXT NOT NULL CHECK (char_length(body) BETWEEN 1 AND 500),
    language TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS comments_video_created_idx ON comments (video_id, created_at DESC, id DESC);
