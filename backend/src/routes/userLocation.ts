import { updateUserLocation } from "../db/users";
import type { Env } from "../index";
import { FeedValidationError, parseLocationBody } from "../validation";

export async function handleUserLocationUpdate(
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

  let latitude: number;
  let longitude: number;
  try {
    ({ latitude, longitude } = parseLocationBody(body));
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid request");
  }

  // Sent by the app while it is closed: stored only while the user shares, and the answer tells the app to stop if not.
  const whileClosed = (body as { whileClosed?: unknown }).whileClosed === true;

  try {
    const sharesLocation = await updateUserLocation(env.DATABASE_URL, userId, latitude, longitude, whileClosed);
    return jsonResponse({ latitude, longitude, sharesLocation });
  } catch {
    return jsonError(500, "failed to store location");
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
