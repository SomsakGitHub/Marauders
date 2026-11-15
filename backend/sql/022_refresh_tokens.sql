-- Refresh tokens for the app. Only the SHA-256 of a token is stored. A sign-in starts a family and each rotation adds the
-- successor to it, so presenting a token that was already spent can revoke everything that descends from that sign-in.
-- used_at marks a token that was rotated, revoked_at one that was cut off (sign-out or reuse). Rows go with their account.

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_users (id) ON DELETE CASCADE,
    family_id UUID NOT NULL,
    token_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);

-- A presented token is found by its hash, and a hash is never stored twice.
CREATE UNIQUE INDEX IF NOT EXISTS refresh_tokens_token_hash_uidx ON refresh_tokens (token_hash);

-- Revoking or checking a family touches every row that shares the family id.
CREATE INDEX IF NOT EXISTS refresh_tokens_family_idx ON refresh_tokens (family_id);
