import { neon } from "@neondatabase/serverless";
import type { Env } from "../index";
import { parseVideoId } from "../validation";
import { audioKey, sourceHash, readAudioBody, validateDubbedAudio } from "../audio/cache";

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

/** Removes every language cached for the clip (all share the `translations/<clip-id>/` prefix). */
export async function deleteDubbedAudio(bucket: R2Bucket, id: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await bucket.list({prefix:`translations/${id.toLowerCase()}/`,cursor});
    if (page.objects.length) await bucket.delete(page.objects.map(object => object.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}
