import { verifyAppleIdentityToken } from "../auth/appleIdentityToken";
import { signAccessToken } from "../auth/accessToken";
import { upsertUserByAppleSub } from "../db/users";
import type { Env } from "../index";
import { FeedValidationError, parseAppleIdentityTokenBody } from "../validation";

export async function handleAppleAuth(
  request: Request,
  env: Env,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.trim().length === 0) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.JWT_SIGNING_SECRET || env.JWT_SIGNING_SECRET.trim().length === 0) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.APPLE_CLIENT_ID || env.APPLE_CLIENT_ID.trim().length === 0) {
    return jsonError(503, "service configuration incomplete");
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "invalid json body");
  }

  let identityToken: string;
  try {
    identityToken = parseAppleIdentityTokenBody(body);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid request");
  }

  try {
    const appleSub = await verifyAppleIdentityToken(
      identityToken,
      env.APPLE_CLIENT_ID,
    );
    const userId = await upsertUserByAppleSub(env.DATABASE_URL, appleSub);
    const accessToken = await signAccessToken(userId, env.JWT_SIGNING_SECRET);
    return jsonResponse({ accessToken });
  } catch {
    return jsonError(401, "invalid apple identity token");
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
