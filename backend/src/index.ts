import { authenticateBearerRequest } from "./auth/authenticateRequest";
import { listFeedVideos } from "./db/feed";
import { clientIp, enforceDatabaseRateLimit, isRateLimited } from "./rateLimit";
import { handleAppleAuth } from "./routes/authApple";
import { handleDevAuth } from "./routes/authDev";
import { handleAvatarDelete, handleAvatarUpload } from "./routes/avatar";
import { handleDubbedAudio, handleDubbedAudioReport } from "./routes/dubbedAudio";
import { parseDubbingLanguage } from "./audio/cache";
import { handleMediaGet } from "./routes/media";
import { handlePublicProfileGet } from "./routes/publicProfile";
import { handleUserLocationUpdate } from "./routes/userLocation";
import { handleUserProfileGet, handleUserProfileUpdate } from "./routes/userProfile";
import { handleVideoDelete } from "./routes/deleteVideo";
import { handleVideoUpload } from "./routes/upload";
import {
  FeedValidationError,
  parseFeedCountry,
  parseFeedCursor,
  parseFeedLimit,
} from "./validation";

export interface Env {
  DATABASE_URL: string;
  VIDEOS: R2Bucket;
  JWT_SIGNING_SECRET: string;
  APPLE_CLIENT_ID: string;
  /** Turns on `/v1/auth/dev` for the debug app on the Simulator; leave unset in normal operation. */
  DEV_LOGIN_SECRET?: string;
  /** General per-IP limit for reads/writes; see wrangler.toml. */
  RATE_LIMITER?: RateLimit;
  /** Stricter per-IP limit for the Apple sign-in endpoint. */
  AUTH_RATE_LIMITER?: RateLimit;
}

const JSON_HEADERS: Record<string, string> = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "private, max-age=0, no-store",
  "x-content-type-options": "nosniff",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function errorResponse(status: number, message: string): Response {
  return jsonResponse({ error: message }, status);
}

function rateLimitedResponse(retryAfterSeconds = 60): Response {
  const response = errorResponse(429, "too many requests");
  response.headers.set("retry-after", String(retryAfterSeconds));
  return response;
}

/** Limit rules for the authoritative Neon-backed limiter. */
const AUTH_RATE_LIMIT = { scope: "auth", limit: 30, windowSeconds: 60 };
const UPLOAD_RATE_LIMIT = { scope: "upload", limit: 10, windowSeconds: 60 };

function withCors(response: Response, request: Request): Response {
  const headers = new Headers(response.headers);
  const origin = request.headers.get("Origin");
  if (origin) {
    headers.set("access-control-allow-origin", origin);
    headers.set("vary", "Origin");
  }
  headers.set("access-control-allow-methods", "GET, POST, PATCH, DELETE, OPTIONS");
  headers.set("access-control-allow-headers", "Content-Type, Authorization, X-Source-SHA256");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function handleFeed(request: Request, env: Env): Promise<Response> {
  if (!env.DATABASE_URL || env.DATABASE_URL.length > 2048) {
    return errorResponse(503, "service configuration incomplete");
  }

  const url = new URL(request.url);
  let limit: number;
  let cursor: string | null;
  let country: string | null;

  try {
    limit = parseFeedLimit(url.searchParams.get("limit"));
    cursor = parseFeedCursor(url.searchParams.get("cursor"));
    country = parseFeedCountry(url.searchParams.get("country"));
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return errorResponse(error.status, error.message);
    }
    return errorResponse(400, "invalid request");
  }

  try {
    // The feed no longer depends on who asks, but a supplied session is still checked: a bad one is an error
    // the app can report, not a feed that quietly looks like a guest's.
    const auth = request.headers.has("Authorization")
      ? await authenticateBearerRequest(request, env.JWT_SIGNING_SECRET ?? "")
      : null;
    if (request.headers.has("Authorization") && !auth) {
      return errorResponse(401, "invalid session");
    }
    // Everyone sees the same clips, the viewer's own included.
    const items = await listFeedVideos(env.DATABASE_URL, limit, cursor, country);
    // `viewerID` stays in the answer: app builds from 8d3657d (feed without own clips) until this change refuse a
    // signed-in feed that lacks it.
    return jsonResponse({ items, viewerID: auth?.userId ?? null });
  } catch {
    return errorResponse(500, "failed to load feed");
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return withCors(new Response(null, { status: 204 }), request);
    }

    const url = new URL(request.url);

    if (url.pathname === "/health" && request.method === "GET") {
      return withCors(jsonResponse({ status: "ok" }), request);
    }

    if (
      url.pathname.startsWith("/v1/") &&
      !url.pathname.startsWith("/v1/media/")
    ) {
      const isAuthRoute =
        url.pathname === "/v1/auth/apple" || url.pathname === "/v1/auth/dev";
      const limiter = isAuthRoute ? env.AUTH_RATE_LIMITER : env.RATE_LIMITER;
      const key = `${isAuthRoute ? "auth" : "api"}:${clientIp(request)}`;
      if (await isRateLimited(limiter, key)) {
        return withCors(rateLimitedResponse(), request);
      }
    }

    if (
      (url.pathname === "/v1/auth/apple" || url.pathname === "/v1/auth/dev") &&
      request.method === "POST"
    ) {
      const decision = await enforceDatabaseRateLimit(
        env.DATABASE_URL,
        AUTH_RATE_LIMIT,
        clientIp(request),
      );
      if (!decision.allowed) {
        return withCors(
          rateLimitedResponse(decision.retryAfterSeconds),
          request,
        );
      }
      const handler =
        url.pathname === "/v1/auth/dev" ? handleDevAuth : handleAppleAuth;
      return withCors(await handler(request, env), request);
    }

    // The map reads the same list as the feed; installed apps still call it by its own path.
    if ((url.pathname === "/v1/feed" || url.pathname === "/v1/map/clips") && request.method === "GET") {
      return withCors(await handleFeed(request, env), request);
    }

    if (url.pathname === "/v1/videos" && request.method === "POST") {
      const auth = await authenticateBearerRequest(
        request,
        env.JWT_SIGNING_SECRET ?? "",
      );
      if (!auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      const decision = await enforceDatabaseRateLimit(
        env.DATABASE_URL,
        UPLOAD_RATE_LIMIT,
        auth.userId,
      );
      if (!decision.allowed) {
        return withCors(
          rateLimitedResponse(decision.retryAfterSeconds),
          request,
        );
      }
      return withCors(
        await handleVideoUpload(request, env, auth.userId),
        request,
      );
    }

    if (url.pathname === "/v1/users/me/location" && request.method === "POST") {
      const auth = await authenticateBearerRequest(
        request,
        env.JWT_SIGNING_SECRET ?? "",
      );
      if (!auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      return withCors(
        await handleUserLocationUpdate(request, env, auth.userId),
        request,
      );
    }

    if (url.pathname === "/v1/users/me" && request.method === "GET") {
      const auth = await authenticateBearerRequest(
        request,
        env.JWT_SIGNING_SECRET ?? "",
      );
      if (!auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      return withCors(
        await handleUserProfileGet(request, env, auth.userId),
        request,
      );
    }

    if (url.pathname === "/v1/users/me" && request.method === "PATCH") {
      const auth = await authenticateBearerRequest(
        request,
        env.JWT_SIGNING_SECRET ?? "",
      );
      if (!auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      return withCors(
        await handleUserProfileUpdate(request, env, auth.userId),
        request,
      );
    }

    if (url.pathname === "/v1/users/me/avatar" && request.method === "POST") {
      const auth = await authenticateBearerRequest(
        request,
        env.JWT_SIGNING_SECRET ?? "",
      );
      if (!auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      const decision = await enforceDatabaseRateLimit(
        env.DATABASE_URL,
        UPLOAD_RATE_LIMIT,
        auth.userId,
      );
      if (!decision.allowed) {
        return withCors(
          rateLimitedResponse(decision.retryAfterSeconds),
          request,
        );
      }
      return withCors(
        await handleAvatarUpload(request, env, auth.userId),
        request,
      );
    }

    if (url.pathname === "/v1/users/me/avatar" && request.method === "DELETE") {
      const auth = await authenticateBearerRequest(
        request,
        env.JWT_SIGNING_SECRET ?? "",
      );
      if (!auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      return withCors(
        await handleAvatarDelete(request, env, auth.userId),
        request,
      );
    }

    if (
      url.pathname.startsWith("/v1/users/") &&
      request.method === "GET"
    ) {
      const rawHandle = decodeURIComponent(url.pathname.slice("/v1/users/".length));
      return withCors(await handlePublicProfileGet(request, env, rawHandle), request);
    }

    const dubbedReportMatch = url.pathname.match(/^\/v1\/videos\/([^/]+)\/dubbed-audio\/report$/);
    if (dubbedReportMatch && request.method === "POST") {
      const auth = await authenticateBearerRequest(request, env.JWT_SIGNING_SECRET ?? "");
      if (!auth) return withCors(errorResponse(401, "authentication required"), request);
      const language = parseDubbingLanguage(url.searchParams.get("lang"));
      if (!language) return withCors(errorResponse(400, "unsupported language"), request);
      const decision = await enforceDatabaseRateLimit(env.DATABASE_URL,
        { scope: "dubbed-audio-report", limit: 10, windowSeconds: 60 }, auth.userId);
      if (!decision.allowed) return withCors(rateLimitedResponse(decision.retryAfterSeconds), request);
      return withCors(await handleDubbedAudioReport(request, env, dubbedReportMatch[1], language, auth.userId), request);
    }

    // `thai-audio` is the original Thai-only path, kept for app versions that predate listening languages.
    const dubbedAudioMatch = url.pathname.match(/^\/v1\/videos\/([^/]+)\/(dubbed-audio|thai-audio)$/);
    if (dubbedAudioMatch && (request.method === "GET" || request.method === "POST")) {
      const language = dubbedAudioMatch[2] === "thai-audio" ? "th" : parseDubbingLanguage(url.searchParams.get("lang"));
      if (!language) return withCors(errorResponse(400, "unsupported language"), request);
      const auth = request.headers.has("Authorization")
        ? await authenticateBearerRequest(request, env.JWT_SIGNING_SECRET ?? "") : null;
      if ((request.headers.has("Authorization") || request.method === "POST") && !auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      if (request.method === "POST") {
        const decision = await enforceDatabaseRateLimit(env.DATABASE_URL,
          { scope: "dubbed-audio-upload", limit: 10, windowSeconds: 60 }, auth!.userId);
        if (!decision.allowed) return withCors(rateLimitedResponse(decision.retryAfterSeconds), request);
      }
      return withCors(await handleDubbedAudio(request, env, dubbedAudioMatch[1], language, auth?.userId), request);
    }

    if (
      url.pathname.startsWith("/v1/videos/") &&
      request.method === "DELETE"
    ) {
      const auth = await authenticateBearerRequest(
        request,
        env.JWT_SIGNING_SECRET ?? "",
      );
      if (!auth) {
        return withCors(errorResponse(401, "authentication required"), request);
      }
      const videoId = decodeURIComponent(url.pathname.slice("/v1/videos/".length));
      return withCors(
        await handleVideoDelete(request, env, videoId, auth.userId),
        request,
      );
    }

    if (
      url.pathname.startsWith("/v1/media/") &&
      (request.method === "GET" || request.method === "HEAD")
    ) {
      const objectKey = decodeURIComponent(url.pathname.slice("/v1/media/".length));
      if (objectKey.includes("..") || objectKey.includes("\\")) {
        return withCors(errorResponse(400, "invalid path"), request);
      }
      return withCors(await handleMediaGet(request, env, objectKey), request);
    }

    if (request.method !== "GET") {
      return withCors(errorResponse(405, "method not allowed"), request);
    }

    return withCors(errorResponse(404, "not found"), request);
  },
};
