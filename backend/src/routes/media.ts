import type { Env } from "../index";
import {
  assertMediaObjectKey,
  contentTypeForMediaKey,
  FeedValidationError,
} from "../validation";

type ByteRange = {
  offset: number;
  length: number;
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

  const head = await env.VIDEOS.head(objectKey);
  if (!head) {
    return new Response("not found", { status: 404 });
  }

  const size = head.size;
  const contentType =
    head.httpMetadata?.contentType ?? contentTypeForMediaKey(objectKey);

  const baseHeaders = new Headers();
  baseHeaders.set("content-type", contentType);
  baseHeaders.set("cache-control", "public, max-age=31536000, immutable");
  baseHeaders.set("x-content-type-options", "nosniff");
  baseHeaders.set("accept-ranges", "bytes");
  baseHeaders.set("content-disposition", "inline");
  if (head.etag) {
    baseHeaders.set("etag", head.etag);
  }

  const ifNoneMatch = request.headers.get("If-None-Match");
  if (
    request.method === "GET" &&
    ifNoneMatch &&
    head.etag &&
    ifNoneMatch === head.etag
  ) {
    return new Response(null, { status: 304, headers: baseHeaders });
  }

  if (request.method === "HEAD") {
    baseHeaders.set("content-length", String(size));
    return new Response(null, { status: 200, headers: baseHeaders });
  }

  const rangeHeader = request.headers.get("Range");
  const range = parseByteRange(rangeHeader, size);

  if (range === "invalid") {
    return new Response("invalid range", {
      status: 416,
      headers: { "content-range": `bytes */${size}` },
    });
  }

  if (range) {
    const object = await env.VIDEOS.get(objectKey, {
      range: { offset: range.offset, length: range.length },
    });
    if (!object) {
      return new Response("not found", { status: 404 });
    }

    const end = range.offset + range.length - 1;
    baseHeaders.set("content-range", `bytes ${range.offset}-${end}/${size}`);
    baseHeaders.set("content-length", String(range.length));

    return new Response(object.body, { status: 206, headers: baseHeaders });
  }

  const object = await env.VIDEOS.get(objectKey);
  if (!object) {
    return new Response("not found", { status: 404 });
  }

  baseHeaders.set("content-length", String(size));
  return new Response(object.body, { status: 200, headers: baseHeaders });
}

function parseByteRange(
  header: string | null,
  size: number,
): ByteRange | null | "invalid" {
  if (!header) {
    return null;
  }

  const match = /^bytes=(\d*)-(\d*)$/u.exec(header.trim());
  if (!match || size < 1) {
    return "invalid";
  }

  const startPart = match[1];
  const endPart = match[2];

  let start = 0;
  let end = size - 1;

  if (startPart !== "") {
    start = Number.parseInt(startPart, 10);
  }
  if (endPart !== "") {
    end = Number.parseInt(endPart, 10);
  }

  if (startPart === "" && endPart !== "") {
    const suffixLength = Number.parseInt(endPart, 10);
    if (!Number.isFinite(suffixLength) || suffixLength < 1) {
      return "invalid";
    }
    start = Math.max(size - suffixLength, 0);
    end = size - 1;
  }

  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start) {
    return "invalid";
  }

  if (start >= size) {
    return "invalid";
  }

  end = Math.min(end, size - 1);
  return { offset: start, length: end - start + 1 };
}
