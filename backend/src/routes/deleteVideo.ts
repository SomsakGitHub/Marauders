import { deleteFeedVideo } from "../db/feed";
import type { Env } from "../index";
import { FeedValidationError, parseVideoId } from "../validation";

const MEDIA_PATH = "/v1/media/";

/** Extracts the R2 object key from a stored public stream URL. */
function objectKeyFromStreamUrl(streamUrl: string): string | null {
  const index = streamUrl.indexOf(MEDIA_PATH);
  if (index < 0) {
    return null;
  }
  const key = streamUrl.slice(index + MEDIA_PATH.length);
  if (key.length === 0 || key.includes("..") || key.includes("\\")) {
    return null;
  }
  return key;
}

export async function handleVideoDelete(
  _request: Request,
  env: Env,
  videoIdRaw: string,
  ownerUserId: string,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }

  let videoId: string;
  try {
    videoId = parseVideoId(videoIdRaw);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid request");
  }

  let streamUrl: string | null;
  try {
    streamUrl = await deleteFeedVideo(env.DATABASE_URL, videoId, ownerUserId);
  } catch {
    return jsonError(500, "failed to delete video");
  }

  if (!streamUrl) {
    return jsonError(404, "video not found");
  }

  const key = objectKeyFromStreamUrl(streamUrl);
  if (key && env.VIDEOS) {
    try {
      await env.VIDEOS.delete(key);
    } catch (storageError) {
      console.error("r2 delete failed", storageError);
    }
  }

  return jsonOk({ deleted: true });
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
