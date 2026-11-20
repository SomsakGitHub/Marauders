// The only place that builds a `wrangler r2 object` command, and the helpers that turn a stream URL into bucket keys.
//
// Every command ends with `--remote`. Without it wrangler 4.150.0 acts on its local simulator: `db:purge` deleted
// database rows only and left every real object in the bucket, and `video:hls` wrote its files to the simulator and
// then pointed `stream_url` at objects that did not exist. test/scripts/r2.test.mjs fails when a script builds the
// command by hand.

/** The arguments of `npx wrangler r2 object <put|delete> <bucket>/<key> …extra --remote` (the leading `wrangler` included). */
export function r2ObjectArgs(action, bucket, key, extra = []) {
  if (action !== "put" && action !== "delete") {
    throw new Error(`r2ObjectArgs builds put and delete only, not "${action}"`);
  }
  return ["wrangler", "r2", "object", action, `${bucket}/${key}`, ...extra, "--remote"];
}

/**
 * Deletes one object with `wrangler r2 object delete … --remote`. `run(args)` runs `npx <args>` and rejects when the
 * command fails. Answers `"deleted"` or `"error: <reason>"`, and never `"missing"`: how wrangler words a key that is not
 * there on a remote bucket has not been seen, and the database rows are the only list of which objects exist, so a
 * failure taken for a miss would delete the rows and leave the objects in the bucket for good. A miss reported as an
 * error costs a re-run (the purge keeps its rows). The reason is wrangler's stderr when there is some, not the error
 * message, which starts with the command line and so holds the key.
 */
export async function deleteR2Object({ run, bucket, key }) {
  try {
    await run(r2ObjectArgs("delete", bucket, key));
    return "deleted";
  } catch (error) {
    return `error: ${failureReason(error)}`;
  }
}

function failureReason(error) {
  const stderr = typeof error?.stderr === "string" ? error.stderr : "";
  const text = stderr.trim() !== "" ? stderr : error instanceof Error ? error.message : String(error);
  return text.replace(/\s+/g, " ").trim().slice(0, 200);
}

/** The bucket key a `/v1/media/` stream URL points at, or null when the URL is not one of ours. */
export function mediaKeyFromStreamUrl(streamUrl) {
  try {
    const pathname = new URL(streamUrl).pathname;
    const prefix = "/v1/media/";
    if (!pathname.startsWith(prefix)) {
      return null;
    }
    return decodeURIComponent(pathname.slice(prefix.length));
  } catch {
    return null;
  }
}

/** Every object a feed row can own: the MP4, or an HLS master playlist plus up to 200 segments (201 deletes). */
export function keysToDeleteForRow(streamUrl) {
  const key = mediaKeyFromStreamUrl(streamUrl);
  if (!key) {
    return [];
  }

  const keys = [key];
  const hlsMatch = /^videos\/[0-9a-f-]{36}\/master\.m3u8$/iu.exec(key);
  if (hlsMatch) {
    const prefix = key.replace(/master\.m3u8$/u, "");
    for (let i = 0; i < 200; i += 1) {
      keys.push(`${prefix}seg${String(i).padStart(3, "0")}.ts`);
    }
  }
  return keys;
}

/** The `stream_url` of an HLS clip stored under `r2Prefix` (for example `videos/<uuid>`), served by the environment's own Worker. */
export function masterStreamUrl(config, r2Prefix) {
  return `${config.url}/v1/media/${r2Prefix}/master.m3u8`;
}
