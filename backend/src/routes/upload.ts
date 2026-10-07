import { insertFeedVideo } from "../db/feed";
import type { Env } from "../index";
import {
  extensionForVideoMime,
  FeedValidationError,
  parseAuthorName,
  parseCaption,
  parseMusicTitle,
  parseUploadFile,
  resolveVideoMime,
} from "../validation";

function publicStreamUrl(request: Request, objectKey: string): string {
  const origin = new URL(request.url).origin;
  return `${origin}/v1/media/${objectKey}`;
}

export async function handleVideoUpload(
  request: Request,
  env: Env,
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
    const file = parseUploadFile(formData.get("file"));
    const authorName = parseAuthorName(formData.get("authorName"));
    const caption = parseCaption(formData.get("caption"));
    const musicTitle = parseMusicTitle(formData.get("musicTitle"));

    const videoId = crypto.randomUUID();
    const mime = resolveVideoMime(file);
    const extension = extensionForVideoMime(mime);
    const objectKey = `videos/${videoId}.${extension}`;

    await env.VIDEOS.put(objectKey, file.stream(), {
      httpMetadata: {
        contentType: mime,
        cacheControl: "public, max-age=31536000, immutable",
      },
    });

    const streamUrl = publicStreamUrl(request, objectKey);
    const item = await insertFeedVideo(env.DATABASE_URL, {
      streamUrl,
      authorName,
      caption,
      musicTitle,
    });

    return jsonOk({ item }, 201);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return jsonError(error.status, error.message);
    }
    return jsonError(500, "upload failed");
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
