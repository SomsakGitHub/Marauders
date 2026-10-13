-- Public, unique @handle per user. New accounts get an auto-generated handle
-- (see src/db/users.ts) and can change it from the profile screen.

ALTER TABLE app_users
    ADD COLUMN IF NOT EXISTS handle VARCHAR(64);

UPDATE app_users
SET handle = '@user_' || substr(replace(id::text, '-', ''), 1, 12)
WHERE handle IS NULL;

ALTER TABLE app_users
    ALTER COLUMN handle SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS app_users_handle_uidx
    ON app_users (handle);

ALTER TABLE app_users
    DROP CONSTRAINT IF EXISTS app_users_handle_format;

ALTER TABLE app_users
    ADD CONSTRAINT app_users_handle_format
    CHECK (handle ~ '^@[a-z0-9._]{1,63}$');
