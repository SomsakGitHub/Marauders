import { signAccessToken } from "../auth/accessToken";
import { generateRefreshToken, hashRefreshToken } from "../auth/refreshToken";
import { revokeRefreshFamily, rotateRefreshToken } from "../db/refreshTokens";
import type { Env } from "../index";
import { FeedValidationError, parseRefreshBody } from "../validation";

/**
 * `POST /v1/auth/refresh`: trades a refresh token for a new pair. The presented token is spent, the successor takes its
 * place in the same family, and the access token is the short, 1-day kind. Every way a token can be unacceptable (unknown,
 * revoked, expired, reused) answers the same 401 body, so the answer says nothing about which check failed. A database
 * failure is a 500 and never a 401, because the app reads a 401 here as "the session is over".
 *
 * Nothing in this file logs: a token, its hash and a driver error that may echo either must not reach a log line.
 */
export async function handleRefresh(request: Request, env: Env): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.JWT_SIGNING_SECRET || env.JWT_SIGNING_SECRET.length < 32) {
    return jsonError(503, "service configuration incomplete");
  }

  const read = await readRefreshToken(request);
  if (read instanceof Response) {
    return read;
  }

  try {
    const successor = generateRefreshToken();
    const result = await rotateRefreshToken(
      env.DATABASE_URL,
      await hashRefreshToken(read),
      await hashRefreshToken(successor),
    );
    if (result.kind === "rejected") {
      return jsonError(401, "invalid refresh token");
    }
    const accessToken = await signAccessToken(result.userId, env.JWT_SIGNING_SECRET, "1d");
    return jsonResponse({ accessToken, refreshToken: successor });
  } catch {
    return jsonError(500, "refresh failed");
  }
}

/**
 * `POST /v1/auth/signout`: revokes the whole family of the presented refresh token. It needs no Bearer token, because
 * the access token may well have expired, and it answers 204 for a token it does not know, so nothing can be learned
 * from the answer.
 */
export async function handleSignOut(request: Request, env: Env): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }

  const read = await readRefreshToken(request);
  if (read instanceof Response) {
    return read;
  }

  try {
    await revokeRefreshFamily(env.DATABASE_URL, await hashRefreshToken(read));
    return new Response(null, { status: 204, headers: HEADERS });
  } catch {
    return jsonError(500, "sign out failed");
  }
}

/** The refresh token of the request body, or the 400 to send back instead. */
async function readRefreshToken(request: Request): Promise<string | Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "invalid json body");
  }
  try {
    return parseRefreshBody(body).refreshToken;
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(400, "invalid request");
  }
}

const HEADERS = {
  "cache-control": "private, max-age=0, no-store",
  "x-content-type-options": "nosniff",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...HEADERS },
  });
}

function jsonError(status: number, message: string): Response {
  return jsonResponse({ error: message }, status);
}
