function spokenLanguage(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const x = value as Record<string, unknown>;
  if (!["likely", "unknown"].includes(x.status as string)) return null;
  if (typeof x.sampledSeconds !== "number" || !Number.isFinite(x.sampledSeconds) || x.sampledSeconds < 0 || x.sampledSeconds > 8) return null;
  const code = typeof x.code === "string" && x.code.length <= 35 && /^[a-z]{2,3}(-[a-z0-9]{2,8})*$/.test(x.code) ? x.code : null;
  const confidence = typeof x.confidence === "number" && Number.isFinite(x.confidence) && x.confidence >= 0 && x.confidence <= 1 ? x.confidence : null;
  if (x.status === "likely" && (!code || confidence === null)) return null;
  const reasons = ["not_attempted", "unreadable", "permission_denied", "model_unavailable", "no_speech", "not_recognized", "ambiguous", "cancelled"];
  return { status: x.status, code: x.status === "likely" ? code : null,
    confidence: x.status === "likely" ? confidence : null,
    reason: reasons.includes(x.reason as string) ? x.reason : null,
    method: x.method === "on_device_speech_analyzer_text" ? "on_device_speech_analyzer_text" : "on_device_speech_text", sampledSeconds: x.sampledSeconds };
}

// Untrusted client advisory; never a translation guarantee.
export function parseAudioAssessment(value: unknown): Record<string, unknown> | null {
 if (typeof value !== "string" || value.length > 2048) return null;
 try {
  const x = JSON.parse(value);
  if (!x || !["speech","music","mixed","unknown"].includes(x.content) || !["detected","noTrack","quietSamples","unknown"].includes(x.signal)) return null;
  for (const k of ["speechConfidence","musicConfidence"]) if (typeof x[k] !== "number" || !Number.isFinite(x[k]) || x[k]<0 || x[k]>1) return null;
  if (typeof x.sampledSeconds !== "number" || !Number.isFinite(x.sampledSeconds) || x.sampledSeconds<0 || x.sampledSeconds>10) return null;
  return { spokenLanguage: spokenLanguage(x.spokenLanguage), content:x.content, signal:x.signal, speechConfidence:x.speechConfidence, musicConfidence:x.musicConfidence, sampledSeconds:x.sampledSeconds, languageHint:typeof x.languageHint === "string" && x.languageHint.length<=35 && /^[a-z]{2,3}(-[a-z0-9]{2,8})*$/.test(x.languageHint) ? x.languageHint : null, exceedsTranslationLimit:x.exceedsTranslationLimit===true, version:1, source:"client-soundanalysis", checkedAt:new Date().toISOString() };
 } catch { return null; }
}
