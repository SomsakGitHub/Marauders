-- Country chosen by the user at sign-in (ISO 3166-1 alpha-2, uppercase).

ALTER TABLE app_users
    ADD COLUMN IF NOT EXISTS country VARCHAR(2);

ALTER TABLE app_users
    DROP CONSTRAINT IF EXISTS app_users_country_iso2;

ALTER TABLE app_users
    ADD CONSTRAINT app_users_country_iso2
    CHECK (country IS NULL OR country ~ '^[A-Z]{2}$');
