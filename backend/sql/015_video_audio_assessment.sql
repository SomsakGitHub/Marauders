-- Optional, untrusted upload-time advisory. Old clips remain unknown.
ALTER TABLE feed_videos ADD COLUMN IF NOT EXISTS audio_assessment jsonb;
