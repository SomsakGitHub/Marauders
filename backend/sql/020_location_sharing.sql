-- Whether the user shows their last known location to the accounts they follow that follow them back. Off until the
-- user turns it on in the app, and a mutual follower sees it only while sharing their own.

ALTER TABLE app_users
    ADD COLUMN IF NOT EXISTS shares_location BOOLEAN NOT NULL DEFAULT false;
