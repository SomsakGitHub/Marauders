import type { Env } from "../index";
import { assertMediaObjectKey, FeedValidationError } from "../validation";

const CONTENT_TYPE_BY_EXT: Record<string, string> = {
  mp4: "video/mp4",
  mov: "video/quicktime",
};

export async function handleMediaGet(
  request: Request,
  env: Env,
  objectKey: string,
): Promise<Response> {
  if (!env.VIDEOS) {
    return new Response("storage not configured", { status: 503 });
  }

  try {
    assertMediaObjectKey(objectKey);
  } catch (error) {
    if (error instanceof FeedValidationError) {
      return new Response(error.message, { status: 400 });
    }
    return new Response("bad request", { status: 400 });
  }

  const object = await env.VIDEOS.get(objectKey);
  if (!object) {
    return new Response("not found", { status: 404 });
  }

  const extension = objectKey.split(".").pop() ?? "mp4";
  const contentType =
    object.httpMetadata?.contentType ??
    CONTENT_TYPE_BY_EXT[extension] ??
    "application/octet-stream";

  const headers = new Headers();
  headers.set("content-type", contentType);
  headers.set("cache-control", "public, max-age=31536000, immutable");
  headers.set("x-content-type-options", "nosniff");

  return new Response(object.body, { status: 200, headers });
}
