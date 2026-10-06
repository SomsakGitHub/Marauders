const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const HTTPS_URL_RE = /^https:\/\/[^\s/$.?#][^\s]*$/i;

export const FEED_LIMIT_DEFAULT = 20;
export const FEED_LIMIT_MAX = 50;

export function parseFeedLimit(raw: string | null): number {
  if (raw === null || raw === "") {
    return FEED_LIMIT_DEFAULT;
  }

  if (!/^\d+$/.test(raw)) {
    throw new FeedValidationError("limit must be a positive integer");
  }

  const limit = Number.parseInt(raw, 10);
  if (limit < 1 || limit > FEED_LIMIT_MAX) {
    throw new FeedValidationError(`limit must be between 1 and ${FEED_LIMIT_MAX}`);
  }

  return limit;
}

export function parseFeedCursor(raw: string | null): string | null {
  if (raw === null || raw === "") {
    return null;
  }

  if (raw.length > 36 || !UUID_RE.test(raw)) {
    throw new FeedValidationError("cursor must be a valid UUID");
  }

  return raw;
}

export function assertHttpsStreamUrl(url: string): void {
  if (url.length > 2048 || !HTTPS_URL_RE.test(url)) {
    throw new FeedValidationError("invalid stream URL in database row");
  }
}

export class FeedValidationError extends Error {
  readonly status = 400;

  constructor(message: string) {
    super(message);
    this.name = "FeedValidationError";
  }
}
