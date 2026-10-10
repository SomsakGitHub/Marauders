const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const HTTPS_URL_RE = /^https:\/\/[^\s/$.?#][^\s]*$/i;

export const FEED_LIMIT_DEFAULT = 20;
export const FEED_LIMIT_MAX = 50;

export const UPLOAD_MAX_BYTES = 100 * 1024 * 1024;

const ALLOWED_VIDEO_MIME = new Set(["video/mp4", "video/quicktime"]);

const MEDIA_OBJECT_KEY_RE =
  /^videos\/[0-9a-f-]{36}\.(mp4|mov)$/;
const MEDIA_HLS_OBJECT_KEY_RE =
  /^videos\/[0-9a-f-]{36}\/(master\.m3u8|seg\d{3}\.ts)$/;

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

export function parseUploadCoordinates(
  latitudeField: MultipartField,
  longitudeField: MultipartField,
): { latitude: number; longitude: number } {
  if (typeof latitudeField !== "string" || typeof longitudeField !== "string") {
    throw new FeedValidationError("latitude and longitude are required");
  }
  const latitudeText = latitudeField.trim();
  const longitudeText = longitudeField.trim();
  if (
    latitudeText.length === 0 ||
    longitudeText.length === 0 ||
    latitudeText.length > 32 ||
    longitudeText.length > 32
  ) {
    throw new FeedValidationError("invalid coordinates");
  }

  const latitude = Number(latitudeText);
  const longitude = Number(longitudeText);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
    throw new FeedValidationError("latitude and longitude must be numbers");
  }
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
    throw new FeedValidationError("coordinates out of range");
  }

  return { latitude, longitude };
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
  if (!MEDIA_OBJECT_KEY_RE.test(key) && !MEDIA_HLS_OBJECT_KEY_RE.test(key)) {
    throw new FeedValidationError("invalid media path");
  }
}

export function contentTypeForMediaKey(objectKey: string): string {
  if (objectKey.endsWith(".m3u8")) {
    return "application/vnd.apple.mpegurl";
  }
  if (objectKey.endsWith(".ts")) {
    return "video/mp2t";
  }
  const extension = objectKey.split(".").pop()?.toLowerCase() ?? "mp4";
  if (extension === "mov") {
    return "video/quicktime";
  }
  return "video/mp4";
}

export function assertHttpsStreamUrl(url: string): void {
  if (url.length > 2048 || !HTTPS_URL_RE.test(url)) {
    throw new FeedValidationError("invalid stream URL in database row");
  }
}

export function parseAppleIdentityTokenBody(body: unknown): string {
  if (!body || typeof body !== "object") {
    throw new FeedValidationError("invalid request body");
  }
  const record = body as Record<string, unknown>;
  const token = record.identityToken;
  if (typeof token !== "string") {
    throw new FeedValidationError("identityToken is required");
  }
  const trimmed = token.trim();
  if (trimmed.length < 20 || trimmed.length > 8192) {
    throw new FeedValidationError("identityToken length is invalid");
  }
  return trimmed;
}

export class FeedValidationError extends Error {
  readonly status = 400;

  constructor(message: string) {
    super(message);
    this.name = "FeedValidationError";
  }
}
