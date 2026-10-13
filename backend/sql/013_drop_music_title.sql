-- Remove the music title field (music was never actually mixed into the video).
ALTER TABLE feed_videos DROP COLUMN IF EXISTS music_title;
