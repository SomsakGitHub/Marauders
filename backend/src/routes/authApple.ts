import { verifyAppleIdentityToken } from "../auth/appleIdentityToken";
import { issueSession } from "../auth/session";
import { upsertUserByAppleSub } from "../db/users";
import type { Env } from "../index";
import { FeedValidationError, parseAppleAuthBody } from "../validation";

export async function handleAppleAuth(
  request: Request,
  env: Env,
): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.JWT_SIGNING_SECRET || env.JWT_SIGNING_SECRET.length < 32) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.APPLE_CLIENT_ID || env.APPLE_CLIENT_ID.length > 256) {
    return jsonError(503, "service configuration incomplete");
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "invalid json body");
  }

  let identityToken: string;
  let country: string | null;
  let supportsRefreshTokens: boolean;
  try {
    ({ identityToken, country, supportsRefreshTokens } = parseAppleAuthBody(body));
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid request");
  }

  let userId: string;
  try {
    const appleSub = await verifyAppleIdentityToken(
      identityToken,
      env.APPLE_CLIENT_ID,
    );
    userId = await upsertUserByAppleSub(env.DATABASE_URL, appleSub, country);
  } catch {
    return jsonError(401, "invalid apple identity token");
  }

  // Outside the try above: a refresh token that cannot be stored is our failure, not a bad identity token.
  try {
    return jsonResponse(await issueSession(env, userId, supportsRefreshTokens));
  } catch {
    return jsonError(500, "sign in failed");
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
