-- Clip coordinates (required for new uploads from the app).

ALTER TABLE feed_videos
    ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION;

ALTER TABLE feed_videos
    ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;

ALTER TABLE feed_videos DROP CONSTRAINT IF EXISTS feed_videos_latitude_range;
ALTER TABLE feed_videos
    ADD CONSTRAINT feed_videos_latitude_range
    CHECK (latitude IS NULL OR (latitude >= -90 AND latitude <= 90));

ALTER TABLE feed_videos DROP CONSTRAINT IF EXISTS feed_videos_longitude_range;
ALTER TABLE feed_videos
    ADD CONSTRAINT feed_videos_longitude_range
    CHECK (longitude IS NULL OR (longitude >= -180 AND longitude <= 180));
