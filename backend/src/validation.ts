const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const HTTPS_URL_RE = /^https:\/\/[^\s/$.?#][^\s]*$/i;

export const FEED_LIMIT_DEFAULT = 20;
export const FEED_LIMIT_MAX = 50;

export const UPLOAD_MAX_BYTES = 100 * 1024 * 1024;

const ALLOWED_VIDEO_MIME = new Set(["video/mp4", "video/quicktime"]);

const MEDIA_OBJECT_KEY_RE = /^videos\/[0-9a-f-]{36}\.(mp4|mov)$/;

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

type MultipartField = string | File | null;

export function resolveVideoMime(file: File): string {
  const declaredMime = file.type.toLowerCase();
  const name = file.name.toLowerCase();
  const mime = ALLOWED_VIDEO_MIME.has(declaredMime)
    ? declaredMime
    : name.endsWith(".mov")
      ? "video/quicktime"
      : name.endsWith(".mp4") || name.endsWith(".m4v")
        ? "video/mp4"
        : declaredMime;

  if (!ALLOWED_VIDEO_MIME.has(mime)) {
    throw new FeedValidationError("file must be MP4 or QuickTime video");
  }
  return mime;
}

export function parseUploadFile(raw: MultipartField): File {
  if (!(raw instanceof File)) {
    throw new FeedValidationError("file is required");
  }
  if (raw.size < 1 || raw.size > UPLOAD_MAX_BYTES) {
    throw new FeedValidationError("file exceeds allowed size (max 100 MB)");
  }
  resolveVideoMime(raw);
  return raw;
}

export function extensionForVideoMime(mime: string): "mp4" | "mov" {
  if (mime === "video/mp4") {
    return "mp4";
  }
  if (mime === "video/quicktime") {
    return "mov";
  }
  throw new FeedValidationError("unsupported video type");
}

export function assertMediaObjectKey(key: string): void {
  if (!MEDIA_OBJECT_KEY_RE.test(key)) {
    throw new FeedValidationError("invalid media path");
  }
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
