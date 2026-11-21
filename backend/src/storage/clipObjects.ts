import { withAttempts } from "../retry";
import { objectKeyFromUrl } from "../routes/avatar";
import { objectKeyFromStreamUrl } from "../routes/deleteVideo";

/** What one clip leaves in the bucket, worked out from its stored stream URL. */
export type ClipObjectPlan =
  | { kind: "exact"; key: string }
  | { kind: "prefix"; prefix: string }
  | { kind: "none" };

/** R2 deletes at most this many keys in one call. */
const MAX_KEYS_PER_DELETE = 1000;

/** A clip made by `npm run video:hls`: a playlist, its segments and the original, all under one lowercase uuid. */
const HLS_CLIP_KEY = /^videos\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\//;

/**
 * Only a key of the exact form videos/<lowercase uuid>/... is deleted by prefix (videos/<uuid>, which also takes the original
 * videos/<uuid>.mov beside the folder); every other key the helper accepts is deleted as that one key, and a URL that is not
 * one of ours, or whose key has two dots or a backslash, names nothing.
 */
export function planClipObjects(streamUrl: string): ClipObjectPlan {
  const key = objectKeyFromStreamUrl(streamUrl);
  if (key === null) {
    return { kind: "none" };
  }
  const hls = HLS_CLIP_KEY.exec(key);
  return hls ? { kind: "prefix", prefix: `videos/${hls[1]}` } : { kind: "exact", key };
}

/**
 * Removes every R2 object of the given clips. Exact keys go out in deletes of at most 1,000; a prefix is listed page by
 * page and each page is deleted before the next is read. Every bucket call is tried up to three times, so a failure that
 * outlasts them rejects and leaves the rest for the next try (a delete of a missing key is not an error).
 */
export async function deleteClipObjects(bucket: R2Bucket, streamUrls: string[]): Promise<void> {
  const exactKeys: string[] = [];
  const prefixes = new Set<string>();
  for (const streamUrl of streamUrls) {
    const plan = planClipObjects(streamUrl);
    if (plan.kind === "exact") {
      exactKeys.push(plan.key);
    } else if (plan.kind === "prefix") {
      prefixes.add(plan.prefix);
    }
  }

  for (let start = 0; start < exactKeys.length; start += MAX_KEYS_PER_DELETE) {
    const chunk = exactKeys.slice(start, start + MAX_KEYS_PER_DELETE);
    await withAttempts(() => bucket.delete(chunk));
  }
  for (const prefix of prefixes) {
    await deletePrefix(bucket, prefix);
  }
}

async function deletePrefix(bucket: R2Bucket, prefix: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await withAttempts(() => bucket.list({ prefix, cursor }));
    if (page.objects.length > 0) {
      const keys = page.objects.map((object) => object.key);
      await withAttempts(() => bucket.delete(keys));
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}

/** Removes the avatar object a stored avatar URL names, when it is one of ours (a key under avatars/). */
export async function deleteAvatarObject(bucket: R2Bucket, avatarUrl: string | null): Promise<void> {
  const key = objectKeyFromUrl(avatarUrl);
  if (key === null) {
    return;
  }
  await withAttempts(() => bucket.delete(key));
}
