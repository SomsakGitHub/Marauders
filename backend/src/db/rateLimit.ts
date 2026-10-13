import { neon } from "@neondatabase/serverless";

type CountRow = { count: number };

/**
 * Atomically increments the counter for `bucketKey` in the given fixed window
 * and returns the new value. Rolling to a new window resets the count to 1.
 */
export async function incrementRateLimitCounter(
  databaseUrl: string,
  bucketKey: string,
  windowStart: Date,
): Promise<number> {
  const sql = neon(databaseUrl);
  const rows = (await sql`
    INSERT INTO rate_limit_counters (bucket_key, window_start, count)
    VALUES (${bucketKey}, ${windowStart.toISOString()}, 1)
    ON CONFLICT (bucket_key) DO UPDATE SET
      count = CASE
        WHEN rate_limit_counters.window_start = EXCLUDED.window_start
          THEN rate_limit_counters.count + 1
        ELSE 1
      END,
      window_start = EXCLUDED.window_start
    RETURNING count
  `) as CountRow[];

  return rows[0]?.count ?? 0;
}
