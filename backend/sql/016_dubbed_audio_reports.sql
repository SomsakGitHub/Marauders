-- Reports against a shared AI dubbed-audio file (one R2 object per clip, source hash and language).
-- Two different reporters remove the audio, and the clip owner or the uploader removes it alone.
-- Rows are cleared when the audio is removed, and with the clip or the user (ON DELETE CASCADE).

CREATE TABLE IF NOT EXISTS dubbed_audio_reports (
    video_id UUID NOT NULL REFERENCES feed_videos (id) ON DELETE CASCADE,
    language TEXT NOT NULL,
    source_hash TEXT NOT NULL,
    reporter_user_id UUID NOT NULL REFERENCES app_users (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (video_id, language, source_hash, reporter_user_id)
);
