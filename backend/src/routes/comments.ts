import { neon } from "@neondatabase/serverless";
import type { Env } from "../index";
import { DUBBING_LANGUAGES } from "../audio/cache";
import { parseVideoId } from "../validation";

export const COMMENT_MAX_CHARS = 500;
/** Line breaks a comment keeps. Each later one is stored as a space, so no comment runs to hundreds of lines. */
export const COMMENT_MAX_LINE_BREAKS = 10;
export const COMMENT_LIMIT_DEFAULT = 30;
export const COMMENT_LIMIT_MAX = 50;
/** A comment is at most 500 code points, about 6 KB of JSON even with every character escaped, so nothing near this is one. */
export const COMMENT_REQUEST_MAX_BYTES = 16 * 1024;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
/**
 * One character a reader can see: not whitespace, not a control, not "default ignorable" (zero-width and directional
 * marks, variation selectors, the Hangul fillers), and not the two that draw nothing but are not ignorable either,
 * the Braille blank and the object replacement character. The app applies the same rule (`CommentRules`).
 */
const VISIBLE_CHARACTER_RE = /[^\p{Default_Ignorable_Code_Point}\p{White_Space}\p{Cc}\u2800\ufffc]/u;
/** With the `u` flag a valid surrogate pair is one code point, so only an unpaired surrogate is left to match. */
const UNPAIRED_SURROGATE_RE = /[\ud800-\udfff]/u;
/** A line break as a text view draws it: CRLF is one, and so are NEL and the Unicode line and paragraph separators. */
const LINE_BREAK_RE = /\r\n|[\n\r\u0085\u2028\u2029]/g;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" },
  });
}

/**
 * Comment text as stored: trimmed (JavaScript's `trim()` leaves a U+0085 at either end; only the app trims that), no
 * control characters other than tab and line breaks (the C0 and C1 controls and DEL are dropped; U+0085 stays, it is a
 * line break). Null when it is empty, has nothing a reader can see (only zero-width or filler characters), contains
 * an unpaired surrogate, or is too long. Only the first 10 line breaks are kept; the rest become spaces.
 */
export function normalizeCommentBody(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const body = raw.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u0084\u0086-\u009f]/g, "").trim();
  if (!body || [...body].length > COMMENT_MAX_CHARS) return null;
  if (UNPAIRED_SURROGATE_RE.test(body) || !VISIBLE_CHARACTER_RE.test(body)) return null;
  // A break that became a space can sit at the edge of the text, so trim once more.
  return limitLineBreaks(body).trim();
}

function limitLineBreaks(text: string): string {
  let seen = 0;
  return text.replace(LINE_BREAK_RE, (lineBreak) => (++seen > COMMENT_MAX_LINE_BREAKS ? " " : lineBreak));
}

/** Base language code of a comment, when it is one the app can translate; Norwegian variants become "nb". */
export function normalizeCommentLanguage(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  let base = raw.trim().toLowerCase().split(/[-_]/)[0];
  if (base === "no" || base === "nn") base = "nb";
  return (DUBBING_LANGUAGES as readonly string[]).includes(base) ? base : null;
}

type CommentRow = {
  id: string; body: string; language: string | null; created_at: string;
  author_user_id: string; handle: string | null; avatar_url: string | null; clip_owner_id: string | null;
};

function commentJSON(row: CommentRow, viewerID: string | null) {
  const viewer = viewerID?.toLowerCase() ?? null;
  return {
    id: row.id,
    body: row.body,
    language: row.language,
    createdAt: new Date(row.created_at).toISOString(),
    authorName: row.handle,
    authorAvatarURL: row.avatar_url,
    canDelete: viewer !== null &&
      (row.author_user_id.toLowerCase() === viewer || (row.clip_owner_id?.toLowerCase() ?? "") === viewer),
  };
}

export async function handleCommentsList(request: Request, env: Env, rawVideoID: string, viewerID: string | null): Promise<Response> {
  let videoID: string;
  try { videoID = parseVideoId(rawVideoID).toLowerCase(); } catch { return json({ error: "invalid video id" }, 400); }
  const url = new URL(request.url);
  const rawLimit = url.searchParams.get("limit");
  const limit = rawLimit === null || rawLimit === "" ? COMMENT_LIMIT_DEFAULT : /^\d+$/.test(rawLimit) ? Number(rawLimit) : 0;
  if (limit < 1 || limit > COMMENT_LIMIT_MAX) return json({ error: `limit must be between 1 and ${COMMENT_LIMIT_MAX}` }, 400);
  const cursor = url.searchParams.get("cursor");
  if (cursor !== null && cursor !== "" && !UUID_RE.test(cursor)) return json({ error: "cursor must be a valid UUID" }, 400);
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  try {
    const sql = neon(env.DATABASE_URL);
    const exists = await sql`SELECT 1 FROM feed_videos WHERE id = ${videoID}::uuid LIMIT 1`;
    if (!exists.length) return json({ error: "video not found" }, 404);
    // Newest first; the cursor is the id of the last comment of the previous page. When that comment has been deleted
    // the comparison below is NULL, so the page comes back empty with no cursor; the app starts over from the newest.
    const rows = (await sql`
      SELECT c.id, c.body, c.language, c.created_at, c.author_user_id, u.handle, u.avatar_url, v.owner_user_id AS clip_owner_id
      FROM comments c
      JOIN app_users u ON u.id = c.author_user_id
      JOIN feed_videos v ON v.id = c.video_id
      WHERE c.video_id = ${videoID}::uuid
        AND (${cursor || null}::uuid IS NULL OR (c.created_at, c.id) < (
          SELECT created_at, id FROM comments WHERE id = ${cursor || null}::uuid AND video_id = ${videoID}::uuid))
      ORDER BY c.created_at DESC, c.id DESC
      LIMIT ${limit + 1}`) as CommentRow[];
    const page = rows.slice(0, limit);
    return json({
      items: page.map(row => commentJSON(row, viewerID)),
      nextCursor: rows.length > limit ? page[page.length - 1].id : null,
    });
  } catch (error) {
    logDatabaseFailure("list", error);
    return json({ error: "failed to load comments" }, 500);
  }
}

class RequestTooLarge extends Error {}

/** The request body as text; throws `RequestTooLarge` as soon as Content-Length, or the bytes read so far, pass `maxBytes`. */
async function readBoundedText(request: Request, maxBytes: number): Promise<string> {
  if (Number(request.headers.get("content-length")) > maxBytes) throw new RequestTooLarge();
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) { await reader.cancel().catch(() => {}); throw new RequestTooLarge(); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  // Decoded once, like request.json(): a character split across two chunks survives, a BOM is dropped.
  return new TextDecoder().decode(bytes);
}

/** What `wrangler tail` shows of a failed statement: the SQLSTATE and the database's message, never the request. */
function logDatabaseFailure(action: string, error: unknown): void {
  const { code, message } = (error ?? {}) as { code?: unknown; message?: unknown };
  console.error(`comments ${action} failed`, typeof code === "string" ? code : "no code", typeof message === "string" ? message : "no message");
}

/** Which foreign key of `comments` an insert broke, when it broke one: the author's account or the clip. */
function violatedForeignKey(error: unknown): "author" | "video" | null {
  const { code, constraint } = (error ?? {}) as { code?: unknown; constraint?: unknown };
  if (code !== "23503") return null;
  // Postgres names an inline `REFERENCES` constraint `<table>_<column>_fkey` (see 017_comments.sql).
  if (constraint === "comments_author_user_id_fkey") return "author";
  if (constraint === "comments_video_id_fkey") return "video";
  return null;
}

export async function handleCommentCreate(request: Request, env: Env, rawVideoID: string, authorID: string): Promise<Response> {
  let videoID: string;
  try { videoID = parseVideoId(rawVideoID).toLowerCase(); } catch { return json({ error: "invalid video id" }, 400); }
  let payload: { body?: unknown; language?: unknown };
  try { payload = JSON.parse(await readBoundedText(request, COMMENT_REQUEST_MAX_BYTES)); }
  catch (error) { return error instanceof RequestTooLarge ? json({ error: "request too large" }, 413) : json({ error: "invalid JSON" }, 400); }
  if (typeof payload !== "object" || payload === null) return json({ error: "invalid JSON" }, 400);
  const body = normalizeCommentBody(payload.body);
  if (!body) return json({ error: `comment must be 1 to ${COMMENT_MAX_CHARS} characters` }, 422);
  const language = normalizeCommentLanguage(payload.language);
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  try {
    const sql = neon(env.DATABASE_URL);
    const rows = (await sql`
      WITH inserted AS (
        INSERT INTO comments (video_id, author_user_id, body, language)
        SELECT v.id, ${authorID}::uuid, ${body}, ${language} FROM feed_videos v WHERE v.id = ${videoID}::uuid
        RETURNING id, body, language, created_at, author_user_id, video_id)
      SELECT i.id, i.body, i.language, i.created_at, i.author_user_id, u.handle, u.avatar_url, v.owner_user_id AS clip_owner_id
      FROM inserted i JOIN app_users u ON u.id = i.author_user_id JOIN feed_videos v ON v.id = i.video_id`) as CommentRow[];
    if (!rows.length) return json({ error: "video not found" }, 404);
    return json({ comment: commentJSON(rows[0], authorID) }, 201);
  } catch (error) {
    // The session token is checked without a database lookup, so it can outlive its account; and the clip can be
    // removed between the check and the insert. Both break a foreign key, and neither can succeed on a retry.
    const broken = violatedForeignKey(error);
    if (broken === "author") return json({ error: "account not found" }, 401);
    if (broken === "video") return json({ error: "video not found" }, 404);
    logDatabaseFailure("create", error);
    return json({ error: "failed to save comment" }, 500);
  }
}

/** The author, or the owner of the clip, removes a comment. */
export async function handleCommentDelete(env: Env, rawVideoID: string, rawCommentID: string, userID: string): Promise<Response> {
  let videoID: string;
  try { videoID = parseVideoId(rawVideoID).toLowerCase(); } catch { return json({ error: "invalid video id" }, 400); }
  if (!UUID_RE.test(rawCommentID)) return json({ error: "invalid comment id" }, 400);
  if (!env.DATABASE_URL) return json({ error: "service configuration incomplete" }, 503);
  try {
    const sql = neon(env.DATABASE_URL);
    const rows = await sql`
      DELETE FROM comments c USING feed_videos v
      WHERE c.id = ${rawCommentID.toLowerCase()}::uuid AND c.video_id = ${videoID}::uuid AND v.id = c.video_id
        AND (c.author_user_id = ${userID}::uuid OR v.owner_user_id = ${userID}::uuid)
      RETURNING c.id`;
    if (!rows.length) return json({ error: "comment not found" }, 404);
    return json({ status: "deleted" });
  } catch (error) {
    logDatabaseFailure("delete", error);
    return json({ error: "failed to delete comment" }, 500);
  }
}
