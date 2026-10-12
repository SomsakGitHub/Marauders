-- Last known location of a user, reported once per app session after the
-- Map tab obtains a location fix. Coordinates are WGS84.

ALTER TABLE app_users
    ADD COLUMN IF NOT EXISTS latitude DOUBLE PRECISION;

ALTER TABLE app_users
    ADD COLUMN IF NOT EXISTS longitude DOUBLE PRECISION;

ALTER TABLE app_users
    ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMPTZ;

ALTER TABLE app_users
    DROP CONSTRAINT IF EXISTS app_users_location_range;

ALTER TABLE app_users
    ADD CONSTRAINT app_users_location_range
    CHECK (
        (latitude IS NULL AND longitude IS NULL)
        OR (
            latitude BETWEEN -90 AND 90
            AND longitude BETWEEN -180 AND 180
        )
    );
