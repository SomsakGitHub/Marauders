# Optional Thai AI narration with a shared server cache

The viewer explicitly chooses original or Thai AI audio. Original playback never requests Thai processing. The app checks for a reusable server audio file before creating a TranslationSession. A cache hit needs neither local speech permission nor translation models. On a miss, speech recognition, English–Thai translation and Thai narration run on the viewer's iPhone.

Completed narration is compressed to AAC/M4A and uploaded to the existing R2 video bucket. Sharing is automatic, with an AI-translation label and original-audio choice; it does not claim endorsement by the clip owner. No paid AI provider, API key, new database table, Worker or bucket is required. Only the existing Worker is updated.

## Cache contract

- GET `/v1/videos/:id/thai-audio?source=<sha256-of-source-url>` returns `missing` or `ready` plus an audio URL. Guests can read cached audio for public clips; a supplied invalid session is rejected.
- POST the same path requires a signed-in session, raw `audio/mp4` body, and `X-Source-SHA256`. Maximum: 4 MiB of structurally valid audio-only AAC with a positive finite duration; there is no fixed duration ceiling. Existing database-backed per-user rate limits apply.
- Immutable R2 key: `translations/<clip-id>/<source-url-sha256>-th-v1.m4a`. Changed clip sources get a different key. Conditional `If-None-Match: *` writes preserve the first completed file when viewers upload concurrently.
- Successful clip deletion cleans all translation keys for that clip. Uploads recheck the source after writing to handle concurrent deletion or source changes.

The server validates MP4 box bounds, movie duration, audio handlers and AAC sample entries, not translation meaning. Two simultaneous first viewers can still both generate locally; once one upload completes, later viewers reuse it. Upload failure leaves local listening available. The upload retains bounded compressed data after the player closes, but terminating the app can interrupt an unfinished transfer.

## Local processing and limitations

Input: English speech, up to 12 MiB, with no fixed duration ceiling. Audio is decoded incrementally to 16 kHz mono PCM WAV in 20-second segments, retaining only a segment-sized PCM buffer rather than the whole decoded clip. Digital silence is omitted. A no-speech segment does not discard words from earlier segments. If all segments are empty, original playback stays available. First use may require system language downloads and speech permission. Backgrounding cancels local processing; leaving or choosing original cleans local media.

The system Thai voice reads one combined translation. It does not preserve speaker identity, background audio or sentence timing. Thai playback restarts the video; longer narration is compressed to fit and shorter narration leaves silence. Words at segment boundaries can be imperfect.

## Verification

The exact Amsterdam clip produced about 22.6 seconds of Thai narration on iPhone 16 Pro Max. The uncached trial took about 75 seconds, including waiting for a no-speech segment. Backend checks cover shared reuse across sessions, concurrent conditional writes, source revisions, malformed/oversized/non-AAC audio and scoped deletion. iOS checks cover revision-bound URLs, authenticated upload, late-result cancellation and a cache hit without constructing a TranslationSession. The existing Worker was deployed and the real Amsterdam narration was uploaded through the signed-in iPhone session. A separate guest client downloaded the shared audio, verified its duration, and a fresh view model reused it without creating a TranslationSession (about 1.2 seconds for the measured lookup and media preparation). The first uncached conversion still has the longer local-processing cost. Temporary live probes are removed from the normal suite.

## Internal upload audio classification

The final exported MP4 is inspected on the iPhone before upload, off the main actor. Up to three one-second windows (start, middle, end) feed Apple's built-in SoundAnalysis classifier. A three-second sampling-work budget, cancellation, decoding failure or unsupported input returns an unknown advisory and never blocks upload. Classification is sampled evidence, not proof about the entire clip or a guarantee that recognition/translation will succeed. Speech and music can coexist. Singing/choir/rapping count as music evidence. Threshold policy: speech >= 0.5, mixed when music also >= 0.5; music only when music >= 0.7 and speech < 0.2; otherwise unknown. These are heuristic scores, not calibrated probabilities.

Language is a sanitized audio-track metadata hint, not language recognition. Missing metadata remains unknown. No speech permissions, downloaded translation models or paid AI calls are needed for classification. The existing 12-MiB local-translation size limit is advisory; duration alone is not a rejection condition; upload limits are unchanged. No diagnostic summary appears on the upload screen. Resetting/changing the selection discards stale results.

The upload sends optional `audioAssessment` JSON. The API bounds and validates fields, discards invalid advisory metadata without blocking upload, and stores the sanitized object in `feed_videos.audio_assessment` (migration 015). It stamps version/source/server receipt time; client-provided scores remain untrusted and must never authorize access or permanently deny translation. Legacy clips have NULL metadata. Feed/map/profile responses include the optional metadata. Shared Thai audio is still checked first; music classifications hide the AI audio entry points in feed and full-screen playback and suppress automatic Thai requests. Speech, mixed, unknown and legacy NULL metadata retain the viewer choice.

Dev inspection: Debug Log tab or Xcode console category `upload.audio-check` shows class, scores, language hint, sampled duration, elapsed time and trial limit. App logs keep 250 entries in RAM. For durable inspection use the existing database console:

```sql
SELECT id, created_at, audio_assessment
FROM feed_videos
ORDER BY created_at DESC
LIMIT 20;
```

Apply only `backend/sql/015_video_audio_assessment.sql` to an existing deployment before deploying the new Worker; do not rerun historical seed/purge migrations. No new external resources are required. Uploads from older app versions and clips uploaded before this feature remain NULL; no backfill is performed.

Physical iPhone verification: the real Amsterdam clip classified as mixed (speech score ~0.94, music ~0.66), sampled ~2.97 seconds, and took ~0.17 seconds after MP4 preparation. This single measurement is not an accuracy benchmark or a full upload-time measurement. Pure music and diverse noisy/multilingual clips still need broader manual evaluation. Backend tests cover metadata bounds, tamper sanitization, parameterized SQL and response round trip, alongside existing feed/auth/shared-audio checks. No test clip was published.

## Spoken-language inspection during upload

Speech/mixed clips now get a separate best-effort language assessment on the uploader's iPhone after SoundAnalysis. This is **not a universal acoustic language identifier**. The device tries up to three available on-device speech recognizers (English, Thai, then device preferred languages, deduplicated by language) on the first eight seconds of normalized audio. Each recognizer has a four-second budget. NaturalLanguage checks the resulting text; short, low-confidence or conflicting evidence remains unknown. First use can request speech recognition permission. Denial, unavailable models, silence or recognition failure never blocks uploading. Music-only clips skip this step. No transcript or clip audio is sent to a cloud language-identification service or included in metadata.

`audioAssessment.spokenLanguage` is optional and distinct from the track's `languageHint`. It records `status` (`likely` / `unknown`), optional language `code` and heuristic `confidence`, an unknown `reason`, `method=on_device_speech_text`, and sampled duration. Scores are not calibrated probabilities and an inferred language does not guarantee successful translation. Backend validation bounds and sanitizes this nested object and persists it in the existing JSONB column; no schema migration is needed. Legacy clips remain without this field. Debug `upload.audio-check` logs the outcome/reason without transcript text. The upload screen continues showing generic preparation progress.

The existing dubbing pipeline still handles English to Thai; this inspection does not add translation support for every detected language. Cached Thai audio continues to be reused normally. In the physical-device check, synthetic English was inferred as English in about 1.2 seconds and synthetic Thai as Thai in about 1.6 seconds, while the previously failing latest clip stayed unknown rather than being labeled English. The live diagnostic was removed from the permanent suite; no new clip was posted and no existing clip's metadata was backfilled.

## Duration ceiling removed

The former 120-second input gate and whole-PCM allocation ceiling are removed. Audio preparation flushes each 20-second segment to disk while decoding; it does not accumulate the entire clip in RAM. The 12-MiB compressed input limit remains, as does the per-segment recognition timeout. Cache encoding and server structural validation no longer impose the previous 180-second audio duration ceiling; the 4-MiB cached audio size bound is unchanged. Older `exceedsTranslationLimit=true` metadata may reflect the former duration policy and is not a playback/translation gate.

A physical-device trial using the actual 141.3-second latest clip decoded seven non-silent chunks and returned a Thai narration file in about 6.9 seconds. The generated narration was about 5.1 seconds; this validates removal of the duration rejection and successful generation, not transcription completeness or translation quality for the entire source. No narration was uploaded during that diagnostic. The permanent normalization test covers 141 seconds and verifies total decoded duration and per-chunk bounds. Backend tests accept longer positive finite durations while retaining bounded AAC validation.

## Spanish language detection with the newer on-device analyzer

The legacy `SFSpeechRecognizer` API on the test iPhone did not support offline Spanish, so the inspector additionally uses iOS 26 `SpeechTranscriber` / `SpeechAnalyzer` for Spanish. It verifies device and locale support and reuses installed assets. Upload never downloads the model itself: if the Spanish model is not installed the Spanish check is skipped and the result stays unknown. Install it ahead of time from Settings → Language models (needs network access once; speech audio and transcript text remain local). Recognizers and the Spanish analyzer run concurrently, so inspection time is bounded by the slowest one. The analyzer has a 12-second processing watchdog for the bounded eight-second sample. A Spanish result is accepted only when the transcribed text's language and confidence support Spanish; legacy candidate evidence is combined conservatively. An uncertain/unsupported result never becomes a hard-coded Spanish label.

The optional `spokenLanguage.code` is `es` when supported by evidence, and `method` is `on_device_speech_analyzer_text` for this path. The API sanitizes and preserves this method and stores the language result in the existing JSONB metadata. No new DB table, service key or storage resource is needed. Spanish-to-Thai dubbing reuses the same analyzer; see below.

Physical-device validation: the previously uncertain clip produced Spanish transcript evidence and `code=es` with about 0.89 heuristic confidence. The new analyzer took about 0.3 seconds after model installation; the complete inspector also selected Spanish. Synthesized English, Thai and Spanish controls all retained their correct language through the combined inspector. No test clip was uploaded or existing metadata backfilled. Backend tests exercise Spanish metadata through validation, parameterized insertion and response round trip; the user can verify a new real upload next.

## Language model downloads (Settings)

The Settings tab lists on-device models with install state and a download button: Translation pairs (English → Thai, Spanish → Thai) and speech-recognition locales (English, Thai, Spanish). Translation downloads use Apple's system prompt and can only be removed in iOS Settings; speech models show progress and can be removed with a swipe. If the English → Thai pair is missing when the user chooses Thai dubbing, the playback message says a one-time download is needed and points here, and dubbing continues once the system download finishes.

## Spanish → Thai dubbing

The dubbing source language comes from the clip's `audioAssessment.spokenLanguage` (`likely` + `es` selects Spanish). Anything else, including legacy clips with no metadata, keeps the English source, so existing behavior is unchanged. English still uses the legacy on-device recognizer; Spanish transcribes each 20-second segment with `SpeechAnalyzer` (shared `SpeechAnalyzerTranscriber`, 60-second per-segment watchdog), then Apple Translation es → th and the system Thai voice. Because the user explicitly chose Thai, the first Spanish run may download the Spanish speech model and the es → th translation pair; both can be installed ahead of time from Settings → Language models. Cached Thai audio is language-independent (same immutable key), so viewers reuse it regardless of source language.

Limits: the detected language is a heuristic and only English and Spanish are routed; a clip detected as another language falls back to the English path and will usually report unclear speech. Translation quality for Spanish was not evaluated beyond a synthesized-speech transcription check on a physical iPhone (about 0.3 seconds for one segment, with correct Spanish text).

## Uploader-chosen spoken language

The upload screen shows a "Language in clip" row for clips that contain speech (hidden for music-only clips and clips without an audio track). It starts at the on-device guess, or "Not sure" when nothing was detected, and the uploader can pick any of about 40 languages. The choice replaces the guess and is sent as `audioAssessment.spokenLanguage` with `status=confirmed`, `method=uploader`, the lowercase language `code`, no confidence and the previous `sampledSeconds` (0 when there was none). Choosing "Not sure" sends `status=unknown`, `reason=uploader_unsure`, `method=uploader`. Picking a different video discards the choice.

The API accepts the new `confirmed` status, `uploader` method and `uploader_unsure` reason: `confirmed` needs a valid code, and a client-supplied confidence is dropped. Like the rest of the assessment this is untrusted advisory metadata: it only selects the dubbing source language and never authorizes anything. Dubbing treats `likely` and `confirmed` alike, so a Spanish choice routes to the Spanish path; any language other than English and Spanish still falls back to the English path until more source languages are added. Stored JSONB needs no migration. Deploy the Worker before shipping the app: an older Worker discards a `confirmed` value as invalid and stores `spokenLanguage` as null.
