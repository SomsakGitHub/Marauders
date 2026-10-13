import { clearUserAvatar, setUserAvatar } from "../db/users";
import type { Env } from "../index";
import {
  avatarMimeFor,
  extensionForAvatarMime,
  FeedValidationError,
  parseAvatarFile,
} from "../validation";

function publicMediaUrl(request: Request, objectKey: string): string {
  const origin = new URL(request.url).origin;
  return `${origin}/v1/media/${objectKey}`;
}

/** Extracts the R2 object key from a stored avatar URL, when it is one of ours. */
function objectKeyFromUrl(url: string | null): string | null {
  if (!url) {
    return null;
  }
  const marker = "/v1/media/";
  const index = url.indexOf(marker);
  if (index < 0) {
    return null;
  }
  const key = url.slice(index + marker.length);
  return key.startsWith("avatars/") ? key : null;
}

/** Uploads (or replaces) the signed-in user's profile avatar. */
export async function handleAvatarUpload(
  request: Request,
  env: Env,
  userId: string,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.VIDEOS) {
    return jsonError(503, "video storage is not configured");
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
    const file = parseAvatarFile(formData.get("file"));
    const mime = avatarMimeFor(file);
    const extension = extensionForAvatarMime(mime);
    const objectKey = `avatars/${crypto.randomUUID()}.${extension}`;
    const body = new Uint8Array(await file.arrayBuffer());

    try {
      await env.VIDEOS.put(objectKey, body, {
        httpMetadata: {
          contentType: mime,
          cacheControl: "public, max-age=31536000, immutable",
        },
      });
    } catch (storageError) {
      console.error("avatar r2 put failed", storageError);
      return jsonError(500, "storage write failed");
    }

    const avatarUrl = publicMediaUrl(request, objectKey);
    let previousUrl: string | null;
    try {
      previousUrl = await setUserAvatar(env.DATABASE_URL, userId, avatarUrl);
    } catch (databaseError) {
      console.error("avatar db update failed", databaseError);
      try {
        await env.VIDEOS.delete(objectKey);
      } catch {
        // best-effort rollback
      }
      return jsonError(500, "failed to update avatar");
    }

    const previousKey = objectKeyFromUrl(previousUrl);
    if (previousKey) {
      try {
        await env.VIDEOS.delete(previousKey);
      } catch {
        // best-effort cleanup of the replaced avatar
      }
    }

    return jsonOk({ avatarURL: avatarUrl }, 201);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    console.error("avatar upload failed", error);
    return jsonError(500, "avatar upload failed");
  }
}

/** Removes the signed-in user's profile avatar. */
export async function handleAvatarDelete(
  _request: Request,
  env: Env,
  userId: string,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }

  try {
    const previousUrl = await clearUserAvatar(env.DATABASE_URL, userId);
    const previousKey = objectKeyFromUrl(previousUrl);
    if (env.VIDEOS && previousKey) {
      try {
        await env.VIDEOS.delete(previousKey);
      } catch {
        // best-effort cleanup
      }
    }
    return jsonOk({ avatarURL: null });
  } catch {
    return jsonError(500, "failed to remove avatar");
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
