import { neon } from "@neondatabase/serverless";
import type { Env } from "../index";
import { parseVideoId } from "../validation";
import { audioKey, textKey, sourceHash, readAudioBody, validateDubbedAudio, DUBBED_TEXT_MAX_BYTES } from "../audio/cache";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {status, headers: {"content-type":"application/json", "cache-control":"no-store"}});
}
async function clipSource(env: Env, id: string): Promise<string | null> {
  const sql = neon(env.DATABASE_URL);
  const rows = await sql`SELECT stream_url FROM feed_videos WHERE id = ${id}::uuid LIMIT 1`;
  return rows[0]?.stream_url as string | undefined ?? null;
}
export async function handleDubbedAudio(request: Request, env: Env, rawID: string, language: string, uploaderID?: string): Promise<Response> {
  let id: string;
  try { id = parseVideoId(rawID).toLowerCase(); } catch { return json({error:"invalid video id"},400); }
  if (!env.DATABASE_URL || !env.VIDEOS) return json({error:"cache unavailable"},503);
  try {
    const source = await clipSource(env,id);
    if (!source) return json({error:"video not found"},404);
    const hash = await sourceHash(source);
    const suppliedHash = request.method === "GET" ? new URL(request.url).searchParams.get("source") : request.headers.get("X-Source-SHA256");
    if (suppliedHash !== hash) return json({error:"clip source changed"},409);
    const key = audioKey(id,hash,language);
    if (new URL(request.url).searchParams.get("kind") === "text") return await handleDubbedText(request, env, id, hash, language, source, uploaderID);
    const ready = () => json({status:"ready",audioURL:`${new URL(request.url).origin}/v1/media/${key}`,sourceHash:hash,language,kind:"ai_translation"});
    if (await env.VIDEOS.head(key)) return ready();
    if (request.method === "GET") return json({status:"missing",sourceHash:hash});
    if (!uploaderID) return json({error:"authentication required"},401);
    if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "audio/mp4") return json({error:"M4A audio required"},415);
    let body: Uint8Array;
    try { body = await readAudioBody(request); validateDubbedAudio(body); }
    catch { return json({error:"invalid or oversized dubbed audio"},422); }
    // First complete audio wins, including two users finishing concurrently.
    await env.VIDEOS.put(key,body,{
      onlyIf: new Headers({"If-None-Match":"*"}),
      httpMetadata:{contentType:"audio/mp4",cacheControl:"public, max-age=31536000, immutable"},
      customMetadata:{kind:"ai_translation",language,uploaderID,sourceHash:hash,version:"1"}
    });
    // A video can be deleted while the client is uploading. Never leave its new cache behind.
    if (await clipSource(env,id) !== source) {
      await env.VIDEOS.delete(key);
      return json({error:"clip source changed"},409);
    }
    if (!await env.VIDEOS.head(key)) return json({error:"cache write incomplete"},503);
    return ready();
  } catch { return json({error:"dubbed audio cache unavailable"},503); }
}

/** Reports needed from different signed-in users before a shared dub is removed (the owner or uploader needs one). */
export const DUBBED_AUDIO_REPORTS_TO_REMOVE = 2;

/**
 * Report a bad shared dub. Removes the audio (and its subtitle text) at once when the reporter owns the clip or
 * uploaded the audio, otherwise when enough different users have reported the same clip, language and source.
 */
export async function handleDubbedAudioReport(request: Request, env: Env, rawID: string, language: string, reporterID: string): Promise<Response> {
  let id: string;
  try { id = parseVideoId(rawID).toLowerCase(); } catch { return json({error:"invalid video id"},400); }
  if (!env.DATABASE_URL || !env.VIDEOS) return json({error:"cache unavailable"},503);
  try {
    const sql = neon(env.DATABASE_URL);
    const rows = await sql`SELECT stream_url, owner_user_id FROM feed_videos WHERE id = ${id}::uuid LIMIT 1`;
    const source = rows[0]?.stream_url as string | undefined;
    if (!source) return json({error:"video not found"},404);
    const hash = await sourceHash(source);
    if (request.headers.get("X-Source-SHA256") !== hash) return json({error:"clip source changed"},409);
    const key = audioKey(id,hash,language);
    const head = await env.VIDEOS.head(key);
    if (!head) {
      // No audio: drop any stale report rows and orphan subtitle so a later replacement starts clean.
      await sql`DELETE FROM dubbed_audio_reports WHERE video_id = ${id}::uuid AND language = ${language} AND source_hash = ${hash}`;
      await env.VIDEOS.delete(textKey(id,hash,language));
      return json({status:"missing"});
    }
    const isOwner = String(rows[0]?.owner_user_id ?? "").toLowerCase() === reporterID.toLowerCase();
    const isUploader = (head.customMetadata?.uploaderID ?? "").toLowerCase() === reporterID.toLowerCase();
    let remove = isOwner || isUploader;
    let reports = 0;
    if (!remove) {
      await sql`INSERT INTO dubbed_audio_reports (video_id, language, source_hash, reporter_user_id)
        VALUES (${id}::uuid, ${language}, ${hash}, ${reporterID}::uuid) ON CONFLICT DO NOTHING`;
      const counted = await sql`SELECT COUNT(*) AS reports FROM dubbed_audio_reports
        WHERE video_id = ${id}::uuid AND language = ${language} AND source_hash = ${hash}`;
      reports = Number(counted[0]?.reports ?? 0);
      remove = reports >= DUBBED_AUDIO_REPORTS_TO_REMOVE;
    }
    if (!remove) return json({status:"reported",reports});
    // Clear the rows first so a failure leaves the audio in place and a retry can finish the removal.
    await sql`DELETE FROM dubbed_audio_reports WHERE video_id = ${id}::uuid AND language = ${language} AND source_hash = ${hash}`;
    await env.VIDEOS.delete([key, textKey(id,hash,language)]);
    return json({status:"removed"});
  } catch { return json({error:"dubbed audio cache unavailable"},503); }
}

/** Removes every language cached for the clip (all share the `translations/<clip-id>/` prefix). */
export async function deleteDubbedAudio(bucket: R2Bucket, id: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await bucket.list({prefix:`translations/${id.toLowerCase()}/`,cursor});
    if (page.objects.length) await bucket.delete(page.objects.map(object => object.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}

/** Subtitles for a saved dub: GET returns the text (or missing), POST saves it once, first writer wins. */
async function handleDubbedText(request: Request, env: Env, id: string, hash: string, language: string, source: string, uploaderID?: string): Promise<Response> {
  const key = textKey(id,hash,language);
  const existing = await env.VIDEOS.get(key);
  if (existing) return json({status:"ready",text:await existing.text(),sourceHash:hash,language});
  if (request.method === "GET") return json({status:"missing",sourceHash:hash});
  if (!uploaderID) return json({error:"authentication required"},401);
  if (!await env.VIDEOS.head(audioKey(id,hash,language))) return json({error:"dubbed audio not saved yet"},409);
  const text = (await request.text()).trim();
  if (!text || new TextEncoder().encode(text).length > DUBBED_TEXT_MAX_BYTES) return json({error:"invalid or oversized dubbed text"},422);
  await env.VIDEOS.put(key,text,{
    onlyIf: new Headers({"If-None-Match":"*"}),
    httpMetadata:{contentType:"text/plain; charset=utf-8",cacheControl:"no-store"},
    customMetadata:{kind:"ai_translation_text",language,uploaderID,sourceHash:hash,version:"1"}
  });
  if (await clipSource(env,id) !== source) {
    await env.VIDEOS.delete(key);
    return json({error:"clip source changed"},409);
  }
  // The audio may have been removed by a report while the text was being saved; never keep an orphan subtitle.
  if (!await env.VIDEOS.head(audioKey(id,hash,language))) {
    await env.VIDEOS.delete(key);
    return json({error:"dubbed audio not saved yet"},409);
  }
  return json({status:"ready",text,sourceHash:hash,language});
}
