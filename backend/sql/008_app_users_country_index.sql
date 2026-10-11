-- Speed up feed filtering by the uploader's country.

CREATE INDEX IF NOT EXISTS app_users_country_idx ON app_users (country);
