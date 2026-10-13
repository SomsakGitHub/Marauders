import { listUserFeedVideos } from "../db/feed";
import { getPublicAccountByHandle } from "../db/users";
import type { Env } from "../index";
import { FeedValidationError, parseHandle } from "../validation";

const PROFILE_VIDEO_LIMIT = 50;

/** Public profile by handle — viewable without authentication (TikTok-style). */
export async function handlePublicProfileGet(
  _request: Request,
  env: Env,
  rawHandle: string,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }

  let handle: string;
  try {
    handle = parseHandle(rawHandle);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid handle");
  }

  try {
    const account = await getPublicAccountByHandle(env.DATABASE_URL, handle);
    if (!account) {
      return jsonError(404, "profile not found");
    }

    const videos = await listUserFeedVideos(
      env.DATABASE_URL,
      account.userId,
      PROFILE_VIDEO_LIMIT,
    );

    return jsonResponse({
      handle: account.handle,
      country: account.country,
      avatarURL: account.avatarURL,
      videoCount: account.videoCount,
      videos,
    });
  } catch {
    return jsonError(500, "failed to load profile");
  }
}

function jsonResponse(body: unknown, status = 200): Response {
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
  return jsonResponse({ error: message }, status);
}
