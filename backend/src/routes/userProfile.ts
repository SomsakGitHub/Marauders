import { listUserFeedVideos } from "../db/feed";
import {
  HandleConflictError,
  getUserProfile,
  updateUserHandle,
} from "../db/users";
import type { Env } from "../index";
import { FeedValidationError, parseHandle } from "../validation";

const PROFILE_VIDEO_LIMIT = 50;

export async function handleUserProfileGet(
  _request: Request,
  env: Env,
  userId: string,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }

  try {
    const profile = await getUserProfile(env.DATABASE_URL, userId);
    if (!profile) {
      return jsonError(404, "profile not found");
    }

    const videos = await listUserFeedVideos(
      env.DATABASE_URL,
      userId,
      PROFILE_VIDEO_LIMIT,
    );

    return jsonResponse({ ...profile, videos });
  } catch {
    return jsonError(500, "failed to load profile");
  }
}

/** Sets the signed-in user's public @handle. */
export async function handleUserProfileUpdate(
  request: Request,
  env: Env,
  userId: string,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "invalid json body");
  }

  let handle: string;
  try {
    const raw = typeof body === "object" && body !== null
      ? (body as { handle?: unknown }).handle
      : undefined;
    handle = parseHandle(raw);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid handle");
  }

  try {
    const updated = await updateUserHandle(env.DATABASE_URL, userId, handle);
    return jsonResponse({ handle: updated });
  } catch (error) {
    if (error instanceof HandleConflictError) {
      return jsonError(409, "handle is already taken");
    }
    return jsonError(500, "failed to update profile");
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
