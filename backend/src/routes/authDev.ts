import { signAccessToken } from "../auth/accessToken";
import { upsertUserByAppleSub } from "../db/users";
import type { Env } from "../index";

const MIN_SECRET_LENGTH = 32;
const LABEL_PATTERN = /^[a-z0-9_-]{1,32}$/;

/**
 * Sign-in for the debug app on the iOS Simulator, which has no Apple ID to offer.
 *
 * Inert until `DEV_LOGIN_SECRET` is set (`wrangler secret put DEV_LOGIN_SECRET`); with it unset or deleted the route
 * answers 404 as if it did not exist. Each `label` maps to one stable user whose `apple_sub` is `dev:<label>`, which
 * can never collide with a real Apple subject.
 */
export async function handleDevAuth(
  request: Request,
  env: Env,
): Promise<Response> {
  const expected = env.DEV_LOGIN_SECRET;
  if (!expected || expected.length < MIN_SECRET_LENGTH) {
    return jsonError(404, "not found");
  }
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return jsonError(503, "service configuration incomplete");
  }
  if (!env.JWT_SIGNING_SECRET || env.JWT_SIGNING_SECRET.length < 32) {
    return jsonError(503, "service configuration incomplete");
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonError(400, "invalid json body");
  }
  if (!body || typeof body !== "object") {
    return jsonError(400, "invalid request body");
  }
  const record = body as Record<string, unknown>;

  if (typeof record.secret !== "string" || !(await secretsMatch(record.secret, expected))) {
    return jsonError(401, "invalid dev login");
  }
  if (typeof record.label !== "string" || !LABEL_PATTERN.test(record.label)) {
    return jsonError(400, "label must be 1-32 chars of a-z 0-9 _ -");
  }

  let country: string | null = null;
  if (record.country !== undefined && record.country !== null) {
    if (typeof record.country !== "string" || !/^[A-Za-z]{2}$/.test(record.country.trim())) {
      return jsonError(400, "country must be a 2-letter ISO code");
    }
    country = record.country.trim().toUpperCase();
  }

  try {
    const userId = await upsertUserByAppleSub(
      env.DATABASE_URL,
      `dev:${record.label}`,
      country,
    );
    const accessToken = await signAccessToken(userId, env.JWT_SIGNING_SECRET);
    return jsonResponse({ accessToken });
  } catch {
    return jsonError(500, "dev login failed");
  }
}

/** Compares SHA-256 digests so the check does not depend on where the strings first differ. */
async function secretsMatch(given: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const left = new Uint8Array(a);
  const right = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) {
    diff |= left[i] ^ right[i];
  }
  return diff === 0;
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
