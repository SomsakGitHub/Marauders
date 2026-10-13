-- Fixed-window rate-limit counters. One row per bucket key (scope + actor),
-- reset in place when the window rolls over. See src/db/rateLimit.ts.
-- Stale rows (old window_start) can be pruned with:
--   DELETE FROM rate_limit_counters WHERE window_start < now() - interval '1 hour';

CREATE TABLE IF NOT EXISTS rate_limit_counters (
    bucket_key TEXT PRIMARY KEY,
    window_start TIMESTAMPTZ NOT NULL,
    count INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS rate_limit_counters_window_start_idx
    ON rate_limit_counters (window_start);
