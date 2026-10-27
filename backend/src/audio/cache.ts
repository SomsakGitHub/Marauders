export const DUBBED_AUDIO_MAX_BYTES = 4 * 1024 * 1024;
export const DUBBED_AUDIO_VERSION = "v1";

/** Languages a viewer can listen in; mirrors the app's listening-language list (BCP-47 base codes). */
export const DUBBING_LANGUAGES: readonly string[] = [
  "ar", "da", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
  "nb", "nl", "pl", "pt", "ru", "sv", "th", "tr", "uk", "vi", "zh",
];

/** Returns the lowercase language code when it is an allowed dubbing language, otherwise null. */
export function parseDubbingLanguage(value: string | null | undefined): string | null {
  const language = value?.trim().toLowerCase();
  return language && DUBBING_LANGUAGES.includes(language) ? language : null;
}

export async function sourceHash(source: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(source)));
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
}
/** One immutable object per clip revision and language; Thai keeps its original `-th-v1` name. */
export function audioKey(id: string, hash: string, language: string): string {
  return `translations/${id.toLowerCase()}/${hash}-${language}-${DUBBED_AUDIO_VERSION}.m4a`;
}

/** The translated words that were read aloud, saved beside the audio so every viewer can read them as subtitles. */
export function textKey(id: string, hash: string, language: string): string {
  return audioKey(id, hash, language).replace(/\.m4a$/, ".txt");
}
export const DUBBED_TEXT_MAX_BYTES = 16 * 1024;

type Box = { type: string; payload: number; end: number };
function boxes(data: Uint8Array, start: number, end: number): Box[] {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const result: Box[] = [];
  let offset = start;
  while (offset < end) {
    if (offset + 8 > end) throw new Error("truncated atom");
    let size = view.getUint32(offset);
    const type = new TextDecoder().decode(data.subarray(offset + 4, offset + 8));
    let header = 8;
    if (size === 1) {
      if (offset + 16 > end) throw new Error("truncated extended atom");
      const large = view.getBigUint64(offset + 8);
      if (large > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("invalid atom size");
      size = Number(large); header = 16;
    } else if (size === 0) { size = end - offset; }
    if (size < header || offset + size > end) throw new Error("invalid atom bounds");
    result.push({type, payload: offset + header, end: offset + size});
    offset += size;
  }
  return result;
}

/** Structural bounds, duration and AAC-only audio; never trusts MIME/extension alone. */
export function validateDubbedAudio(data: Uint8Array): void {
  if (data.length < 32 || data.length > DUBBED_AUDIO_MAX_BYTES) throw new Error("invalid audio size");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const root = boxes(data, 0, data.length);
  if (!root.some(b => b.type === "ftyp") || !root.some(b => b.type === "mdat" && b.end > b.payload)) throw new Error("invalid M4A");
  const moov = root.find(b => b.type === "moov");
  if (!moov) throw new Error("missing audio metadata");
  const children = boxes(data, moov.payload, moov.end);
  const header = children.find(b => b.type === "mvhd");
  if (!header || header.payload + 20 > header.end) throw new Error("missing duration");
  const version = data[header.payload];
  if (version !== 0 && version !== 1) throw new Error("unsupported duration");
  if (version === 1 && header.payload + 32 > header.end) throw new Error("truncated duration");
  const scale = view.getUint32(header.payload + (version === 1 ? 20 : 12));
  const ticks = version === 1 ? Number(view.getBigUint64(header.payload + 24)) : view.getUint32(header.payload + 16);
  const duration = ticks / scale;
  if (!Number.isFinite(duration) || duration <= 0) throw new Error("unsupported duration");
  let audio = false;
  for (const track of children.filter(b => b.type === "trak")) {
    const mdia = boxes(data, track.payload, track.end).find(b => b.type === "mdia");
    if (!mdia) throw new Error("missing track media");
    const media = boxes(data, mdia.payload, mdia.end);
    const handler = media.find(b => b.type === "hdlr");
    if (!handler || handler.payload + 12 > handler.end) throw new Error("missing track handler");
    if (new TextDecoder().decode(data.subarray(handler.payload + 8, handler.payload + 12)) !== "soun") throw new Error("audio-only required");
    const minf = media.find(b => b.type === "minf");
    const stbl = minf && boxes(data, minf.payload, minf.end).find(b => b.type === "stbl");
    const stsd = stbl && boxes(data, stbl.payload, stbl.end).find(b => b.type === "stsd");
    if (!stsd || stsd.payload + 8 > stsd.end) throw new Error("missing AAC description");
    const entries = boxes(data, stsd.payload + 8, stsd.end);
    if (!entries.length || entries.some(b => b.type !== "mp4a")) throw new Error("AAC audio required");
    audio = true;
  }
  if (!audio) throw new Error("missing audio track");
}

export async function readAudioBody(request: Request): Promise<Uint8Array> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > DUBBED_AUDIO_MAX_BYTES) throw new Error("audio too large");
  if (!request.body) throw new Error("missing audio");
  const reader = request.body.getReader();
  const pieces: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const item = await reader.read();
      if (item.done) break;
      size += item.value.byteLength;
      if (size > DUBBED_AUDIO_MAX_BYTES) { await reader.cancel(); throw new Error("audio too large"); }
      pieces.push(item.value);
    }
  } finally { reader.releaseLock(); }
  const data = new Uint8Array(size);
  let offset = 0;
  for (const piece of pieces) { data.set(piece, offset); offset += piece.length; }
  return data;
}
