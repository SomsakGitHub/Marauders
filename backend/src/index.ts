import { authenticateBearerRequest } from "./auth/authenticateRequest";
import { listFeedVideos } from "./db/feed";
import { handleAppleAuth } from "./routes/authApple";
import { handleMediaGet } from "./routes/media";
import { handleVideoUpload } from "./routes/upload";
import {
  FeedValidationError,
  parseFeedCursor,
  parseFeedLimit,
} from "./validation";

export interface Env {
  DATABASE_URL: string;
  VIDEOS: R2Bucket;
  JWT_SIGNING_SECRET: string;
  APPLE_CLIENT_ID: string;
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

function withCors(response: Response, request: Request): Response {
  const headers = new Headers(response.headers);
  const origin = request.headers.get("Origin");
  if (origin) {
    headers.set("access-control-allow-origin", origin);
    headers.set("vary", "Origin");
  }
  headers.set("access-control-allow-methods", "GET, POST, OPTIONS");
  headers.set("access-control-allow-headers", "Content-Type, Authorization");
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

  try {
    limit = parseFeedLimit(url.searchParams.get("limit"));
    cursor = parseFeedCursor(url.searchParams.get("cursor"));
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return errorResponse(error.status, error.message);
    }
    return errorResponse(400, "invalid request");
  }

  try {
    const items = await listFeedVideos(env.DATABASE_URL, limit, cursor);
    return jsonResponse({ items });
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

    if (url.pathname === "/v1/auth/apple" && request.method === "POST") {
      return withCors(await handleAppleAuth(request, env), request);
    }

    if (url.pathname === "/v1/feed" && request.method === "GET") {
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
      return withCors(
        await handleVideoUpload(request, env, auth.userId),
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
