import { incrementRateLimitCounter } from "./db/rateLimit";

/** Best-effort client identifier: Cloudflare's connecting IP, then XFF. */
export function clientIp(request: Request): string {
  const connectingIp = request.headers.get("CF-Connecting-IP");
  if (connectingIp && connectingIp.trim().length > 0) {
    return connectingIp.trim();
  }

  const forwardedFor = request.headers.get("X-Forwarded-For");
  const first = forwardedFor?.split(",")[0]?.trim();
  if (first && first.length > 0) {
    return first;
  }

  return "unknown";
}

/**
 * Cheap first line of defence using Cloudflare's Rate Limiting binding
 * (per-location, no extra latency). Returns true when the request should be
 * rejected. Fails open when the binding is missing or errors.
 */
export async function isRateLimited(
  limiter: RateLimit | undefined,
  key: string,
): Promise<boolean> {
  if (!limiter) {
    return false;
  }

  try {
    const { success } = await limiter.limit({ key });
    return !success;
  } catch {
    return false;
  }
}

export type RateLimitRule = {
  /** Bucket scope, e.g. "auth" or "upload". */
  scope: string;
  /** Allowed requests within one window. */
  limit: number;
  /** Window length in seconds (fixed window aligned to the epoch). */
  windowSeconds: number;
};

export type RateLimitDecision =
  | { allowed: true }
  | { allowed: false; retryAfterSeconds: number };

/**
 * Authoritative limiter backed by Neon. Uses an atomic fixed-window counter,
 * so concurrent requests in the same Cloudflare location (or across locations)
 * share one accurate count. Fails open if the database is unreachable so a
 * storage blip never locks every user out.
 */
export async function enforceDatabaseRateLimit(
  databaseUrl: string | undefined,
  rule: RateLimitRule,
  actorId: string,
  now: Date = new Date(),
): Promise<RateLimitDecision> {
  if (!databaseUrl) {
    return { allowed: true };
  }

  const windowMs = rule.windowSeconds * 1000;
  const windowStartMs = Math.floor(now.getTime() / windowMs) * windowMs;
  const windowStart = new Date(windowStartMs);
  const bucketKey = `${rule.scope}:${actorId}`;

  let count: number;
  try {
    count = await incrementRateLimitCounter(databaseUrl, bucketKey, windowStart);
  } catch {
    return { allowed: true };
  }

  if (count <= rule.limit) {
    return { allowed: true };
  }

  const retryAfterMs = windowStartMs + windowMs - now.getTime();
  return {
    allowed: false,
    retryAfterSeconds: Math.max(1, Math.ceil(retryAfterMs / 1000)),
  };
}
