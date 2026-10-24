// Untrusted client advisory; never a translation guarantee.
export function parseAudioAssessment(value: unknown): Record<string, unknown> | null {
 if (typeof value !== "string" || value.length > 2048) return null;
 try {
  const x = JSON.parse(value);
  if (!x || !["speech","music","mixed","unknown"].includes(x.content) || !["detected","noTrack","quietSamples","unknown"].includes(x.signal)) return null;
  for (const k of ["speechConfidence","musicConfidence"]) if (typeof x[k] !== "number" || !Number.isFinite(x[k]) || x[k]<0 || x[k]>1) return null;
  if (typeof x.sampledSeconds !== "number" || !Number.isFinite(x.sampledSeconds) || x.sampledSeconds<0 || x.sampledSeconds>10) return null;
  return { content:x.content, signal:x.signal, speechConfidence:x.speechConfidence, musicConfidence:x.musicConfidence, sampledSeconds:x.sampledSeconds, languageHint:typeof x.languageHint === "string" && x.languageHint.length<=35 && /^[a-z]{2,3}(-[a-z0-9]{2,8})*$/.test(x.languageHint) ? x.languageHint : null, exceedsTranslationLimit:x.exceedsTranslationLimit===true, version:1, source:"client-soundanalysis", checkedAt:new Date().toISOString() };
 } catch { return null; }
}
