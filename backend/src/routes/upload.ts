import { parseAudioAssessment } from "../audio/assessment";
import {
  findFeedVideoByUploadKey,
  insertFeedVideo,
  UploadKeyConflictError,
} from "../db/feed";
import {
  MP4_FASTSTART_MAX_BYTES,
  mp4ApplyFastStart,
} from "../media/mp4FastStart";
import type { Env } from "../index";
import {
  extensionForVideoMime,
  FeedValidationError,
  parseUploadCaption,
  parseUploadCoordinates,
  parseUploadFile,
  parseUploadIdempotencyKey,
  resolveVideoMime,
} from "../validation";

function publicStreamUrl(request: Request, objectKey: string): string {
  const origin = new URL(request.url).origin;
  return `${origin}/v1/media/${objectKey}`;
}

export async function handleVideoUpload(
  request: Request,
  env: Env,
  ownerUserId: string,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.VIDEOS) {
    return jsonError(503, "video storage is not configured");
  }

  // The key is read before the body: a replay carries none, and a key that is already stored answers without one.
  let uploadKey: string | null;
  try {
    uploadKey = parseUploadIdempotencyKey(request.headers.get("Idempotency-Key"));
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    throw error;
  }
  if (uploadKey !== null) {
    try {
      const stored = await findFeedVideoByUploadKey(env.DATABASE_URL, ownerUserId, uploadKey);
      if (stored) {
        return jsonOk({ item: stored }, 200);
      }
    } catch (lookupError) {
      // Falling through to a new upload could make the duplicate the key exists to prevent.
      console.error("upload key lookup failed", lookupError);
      return jsonError(500, "upload lookup failed");
    }
  }

  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().startsWith("multipart/form-data")) {
    return jsonError(400, "expected multipart form data");
  }

  let formData: FormData;
  try {
    formData = await request.formData();
  } catch {
    return jsonError(400, "invalid multipart body");
  }

  try {
    const file = parseUploadFile(formData.get("file"));
    const coordinates = parseUploadCoordinates(
      formData.get("latitude"),
      formData.get("longitude"),
    );
    const caption = parseUploadCaption(formData.get("caption"));

    const videoId = crypto.randomUUID();
    const mime = resolveVideoMime(file);
    const extension = extensionForVideoMime(mime);
    const objectKey = `videos/${videoId}.${extension}`;

    let body = new Uint8Array(await file.arrayBuffer());
    if (
      mime === "video/mp4" &&
      body.byteLength > 0 &&
      body.byteLength <= MP4_FASTSTART_MAX_BYTES
    ) {
      body = new Uint8Array(mp4ApplyFastStart(body));
    }

    try {
      await env.VIDEOS.put(objectKey, body, {
        httpMetadata: {
          contentType: mime,
          cacheControl: "public, max-age=31536000, immutable",
        },
      });
    } catch (storageError) {
      console.error("r2 put failed", storageError);
      return jsonError(500, "storage write failed");
    }

    const streamUrl = publicStreamUrl(request, objectKey);
    let item;
    try {
      item = await insertFeedVideo(
        env.DATABASE_URL,
        streamUrl,
        coordinates.latitude,
        coordinates.longitude,
        ownerUserId,
        caption,
        parseAudioAssessment(formData.get("audioAssessment")),
        uploadKey,
      );
    } catch (databaseError) {
      console.error("database insert failed", databaseError);
      try {
        await env.VIDEOS.delete(objectKey);
      } catch {
        // best-effort rollback
      }
      if (databaseError instanceof UploadKeyConflictError && uploadKey !== null) {
        // A request with the same key stored its clip first: answer with that clip.
        try {
          const winner = await findFeedVideoByUploadKey(env.DATABASE_URL, ownerUserId, uploadKey);
          if (winner) {
            return jsonOk({ item: winner }, 200);
          }
        } catch (lookupError) {
          console.error("upload key lookup failed", lookupError);
        }
      }
      const detail =
        databaseError instanceof Error ? databaseError.message : "unknown";
      return jsonError(500, `database write failed: ${detail.slice(0, 160)}`);
    }

    return jsonOk({ item }, 201);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    console.error("upload failed", error);
    const detail = error instanceof Error ? error.message : "unknown";
    return jsonError(500, `upload failed: ${detail.slice(0, 160)}`);
  }
}

function jsonOk(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "private, max-age=0, no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function jsonError(status: number, message: string): Response {
  return jsonOk({ error: message }, status);
}
