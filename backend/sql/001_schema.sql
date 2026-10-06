-- Run in Neon SQL Editor (project: org-dawn-glade-96157792) or: psql "$DATABASE_URL" -f sql/001_schema.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS feed_videos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stream_url TEXT NOT NULL,
    author_name VARCHAR(64) NOT NULL,
    caption VARCHAR(500) NOT NULL,
    music_title VARCHAR(200) NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT feed_videos_stream_url_https CHECK (stream_url ~ '^https://'),
    CONSTRAINT feed_videos_author_name_format CHECK (author_name ~ '^@[A-Za-z0-9._]{1,63}$'),
    CONSTRAINT feed_videos_sort_order_non_negative CHECK (sort_order >= 0)
);

CREATE INDEX IF NOT EXISTS feed_videos_feed_order_idx
    ON feed_videos (sort_order DESC, created_at DESC);
