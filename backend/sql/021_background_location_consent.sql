-- Location sharing now also sends where the user is while Marauders is closed. Everyone who turned it on before agreed
-- only to where they last used the app, so it is turned off once and the app asks them again. db:migrate replays every
-- file, so the reset is tied to a row in data_migrations and runs only the first time.

CREATE TABLE IF NOT EXISTS data_migrations (
    name TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

WITH applied AS (
    INSERT INTO data_migrations (name) VALUES ('021_background_location_consent')
    ON CONFLICT (name) DO NOTHING
    RETURNING name
)
UPDATE app_users SET shares_location = false
WHERE shares_location AND EXISTS (SELECT 1 FROM applied);
