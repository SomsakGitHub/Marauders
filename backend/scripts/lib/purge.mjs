// The order of `db:purge`: count what is there, ask for the phrase, delete the objects, then the rows.
// The rows are the only list of which objects exist, so they are deleted last and only when every object delete
// worked (or the deleter says the object was already gone, which the wrangler one never does: see r2.mjs): a failed
// run leaves them in place and a re-run can try again.
// The database and the bucket arrive as arguments, so test/scripts/purge.test.mjs runs this with fakes.

import { keysToDeleteForRow } from "./r2.mjs";

/**
 * `sql` is the Neon tagged-template function, `confirm(phrase)` stops the run by throwing, and
 * `deleteObject(bucket, key)` answers `"deleted"`, `"missing"` or `"error: …"`.
 */
export async function purgeVideos({ sql, config, confirm, deleteObject, log }) {
  const rows = await sql`SELECT id, stream_url FROM feed_videos ORDER BY created_at ASC`;
  log(`feed_videos rows: ${rows.length}`);

  const keySet = new Set();
  for (const row of rows) {
    for (const key of keysToDeleteForRow(row.stream_url)) {
      keySet.add(key);
    }
  }
  log(`r2 objects to try in ${config.bucket}: ${keySet.size}`);

  await confirm(config.confirm.purge);

  let deleted = 0;
  let missing = 0;
  let errors = 0;
  for (const key of keySet) {
    const result = await deleteObject(config.bucket, key);
    if (result === "deleted") {
      deleted += 1;
      log(`  deleted ${key}`);
    } else if (result === "missing") {
      missing += 1;
    } else {
      errors += 1;
      log(`  ${key}: ${result}`);
    }
  }
  if (errors > 0) {
    throw new Error(
      `${errors} object delete(s) failed, so the database rows were left in place and a re-run can try again`,
    );
  }

  const removed = await sql`DELETE FROM feed_videos RETURNING id`;
  log(`database rows removed: ${removed.length}`);
  log(`r2 deleted=${deleted} missing=${missing}`);
  return { rows: rows.length, keys: keySet.size, deleted, missing, errors, removed: removed.length };
}
