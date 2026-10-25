# Optional AI dubbing into the viewer's language, with a shared server cache

The viewer explicitly chooses original or AI audio in their listening language (see "Listening language" below; the first version only produced Thai). Original playback never requests AI processing. The app checks for a reusable server audio file before creating a TranslationSession. A cache hit needs neither local speech permission nor translation models. On a miss, speech recognition, translation and narration in the listening language run on the viewer's iPhone.

Completed narration is compressed to AAC/M4A and uploaded to the existing R2 video bucket. Sharing is automatic, with an AI-translation label and original-audio choice; it does not claim endorsement by the clip owner. No paid AI provider, API key, new database table, Worker or bucket is required. Only the existing Worker is updated.

## Cache contract

- GET `/v1/videos/:id/dubbed-audio?source=<sha256-of-source-url>&lang=<code>` returns `missing` or `ready` plus an audio URL and the `language`. `lang` is one of the 22 listening languages (`ar da de en es fr hi id it ja ko nb nl pl pt ru sv th tr uk vi zh`, case-insensitive); anything else is a 400. Guests can read cached audio for public clips; a supplied invalid session is rejected. The original `/thai-audio` path is kept for app versions that predate listening languages and behaves as `lang=th`.
- POST the same path (with `lang`) requires a signed-in session, raw `audio/mp4` body, and `X-Source-SHA256`. Maximum: 4 MiB of structurally valid audio-only AAC with a positive finite duration; there is no fixed duration ceiling. Existing database-backed per-user rate limits apply.
- Immutable R2 key: `translations/<clip-id>/<source-url-sha256>-<lang>-v1.m4a` (Thai keeps its original `-th-v1` name, so existing objects remain valid). Each language is cached independently and never served for another language. Changed clip sources get a different key. Conditional `If-None-Match: *` writes preserve the first completed file when viewers upload concurrently.
- Successful clip deletion cleans all translation keys for that clip, in every language. Uploads recheck the source after writing to handle concurrent deletion or source changes.

The server validates MP4 box bounds, movie duration, audio handlers and AAC sample entries, not translation meaning. Two simultaneous first viewers can still both generate locally; once one upload completes, later viewers reuse it. Upload failure leaves local listening available. The upload retains bounded compressed data after the player closes, but terminating the app can interrupt an unfinished transfer.

## Local processing and limitations

Input: English or Spanish speech, up to 12 MiB, with no fixed duration ceiling. Audio is decoded incrementally to 16 kHz mono PCM WAV in 20-second segments, retaining only a segment-sized PCM buffer rather than the whole decoded clip. Digital silence is omitted. A no-speech segment does not discard words from earlier segments. If all segments are empty, original playback stays available. First use may require system language downloads and speech permission. Backgrounding cancels local processing; leaving or choosing original cleans local media.

The system voice for the listening language reads one combined translation. It does not preserve speaker identity, background audio or sentence timing. Dubbed playback restarts the video; longer narration is compressed to fit and shorter narration leaves silence. Words at segment boundaries can be imperfect.

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

## Language detection (moved to the viewer's iPhone)

Upload no longer detects the spoken language. It used to run speech recognizers on the uploader's iPhone, which only covered the few languages that phone happened to have models for, asked the uploader for speech-recognition permission, and made every upload wait. The detection now runs on the **viewer's** iPhone, only when that viewer asks for AI audio and no saved audio exists, so most viewers never pay for it. Upload still classifies the audio (speech, music or mixed, via SoundAnalysis) because music-only clips offer no AI audio; that is not language detection.

What the viewer's iPhone does when the clip does not declare its language (new uploads never do; see "Clips that declare a language") and it has not been detected on this phone before:

1. Look for saved AI audio in the viewer's language (a hit needs no detection, no permission and no models).
2. Ask for speech-recognition permission, download the clip (bounded to 12 MiB) and cut the first non-silent segment (up to 20 seconds).
3. Recognize that sample as each language the app can dub from and as the viewer's own language, and check what language the transcript really reads as (NaturalLanguage). A recognizer forced onto the wrong language produces gibberish that fails this check, so it yields no evidence rather than a confident wrong answer. A transcript counts only when the recognizer was reasonably sure (confidence at least 0.45), the text has at least 12 letters and reads as the requested language with at least 0.8 confidence; the evidence score is the smaller of the two.
4. Languages whose models are already installed go first, all at once. If the best result reaches 0.8 it is accepted. Otherwise the remaining languages get a turn, which may download a speech model once, so an English clip never makes a phone fetch a Spanish model. If two different languages end within 0.15 of each other the result is ambiguous and nothing is chosen.
5. The answer is remembered on that phone for the clip (a local list capped at 300 clips). If it equals the viewer's language the player says the clip is already in it and keeps the original audio, and the audio button stops being offered for that clip. If it is a language the app cannot dub from yet, the player says so. If nothing is clear, the player says it could not tell.

This is still **not an acoustic language identifier**: it can only name a language the viewer's iPhone has a recognizer for. Audio, transcripts and the result never leave the phone, and nothing is stored on the server (the `audioAssessment.spokenLanguage` field is only present on clips uploaded by older builds, see below). The per-clip memo is not shared between viewers, so each phone detects a clip once; sharing it through the server would need a write path with the same first-write-wins trust problem as the audio cache.

## Duration ceiling removed

The former 120-second input gate and whole-PCM allocation ceiling are removed. Audio preparation flushes each 20-second segment to disk while decoding; it does not accumulate the entire clip in RAM. The 12-MiB compressed input limit remains, as does the per-segment recognition timeout. Cache encoding and server structural validation no longer impose the previous 180-second audio duration ceiling; the 4-MiB cached audio size bound is unchanged. Older `exceedsTranslationLimit=true` metadata may reflect the former duration policy and is not a playback/translation gate.

A physical-device trial using the actual 141.3-second latest clip decoded seven non-silent chunks and returned a Thai narration file in about 6.9 seconds. The generated narration was about 5.1 seconds; this validates removal of the duration rejection and successful generation, not transcription completeness or translation quality for the entire source. No narration was uploaded during that diagnostic. The permanent normalization test covers 141 seconds and verifies total decoded duration and per-chunk bounds. Backend tests accept longer positive finite durations while retaining bounded AAC validation.

## Speech recognition for Spanish (and other analyzer languages)

The legacy `SFSpeechRecognizer` on the test iPhone did not support offline Spanish, so Spanish uses iOS 26 `SpeechTranscriber` / `SpeechAnalyzer` (shared `SpeechAnalyzerTranscriber`). It verifies device and locale support and reuses installed assets; a missing model is downloaded only when the caller allows it (the viewer asked for AI audio, or detection ran out of installed options). The analyzer has a watchdog (12 seconds for a detection sample, 60 seconds per dubbing segment). Physical-device check: Spanish text was recognized from synthesized speech in about 0.3 seconds with a heuristic confidence of about 0.9. Audio and text stay on the device.

## Language model downloads (Settings)

The Settings tab lists on-device models with install state and a download button: Translation pairs (English → Thai, Spanish → Thai) and speech-recognition locales (English, Thai, Spanish). Translation downloads use Apple's system prompt and can only be removed in iOS Settings; speech models show progress and can be removed with a swipe. If the English → Thai pair is missing when the user chooses Thai dubbing, the playback message says a one-time download is needed and points here, and dubbing continues once the system download finishes.

## Spanish → Thai dubbing

_Thai was the first and only target; it is now one of 22 listening languages (see the last section), and everything below applies to the chosen language._

The dubbing source language comes from, in order: the language an older clip declares in `audioAssessment.spokenLanguage` (the uploader's choice or an upload-time guess from earlier builds), what this iPhone detected for the clip earlier, or a detection run now (see "Language detection"). English transcribes with the legacy on-device recognizer; Spanish transcribes each 20-second segment with `SpeechAnalyzer` (shared `SpeechAnalyzerTranscriber`, 60-second per-segment watchdog); then Apple Translation into the listening language and the system voice. Because the viewer explicitly asked for AI audio, the first Spanish run may download the Spanish speech model and the translation pair; both can be installed ahead of time from Settings → Language models. Cached audio is per (clip, language), independent of the source language, so viewers reuse it regardless of how the source was found.

Limits: only English and Spanish are routed as sources. A clip known or detected to be in any other language keeps the original audio and the player says dubbing from it is not supported yet. Translation quality for Spanish was not evaluated beyond a synthesized-speech transcription check on a physical iPhone.

## Clips that declare a language (older builds)

New uploads never carry a language. The uploader's side has no need to name or detect it, so the upload screen has no language row; it briefly had an optional "Language in clip" picker, which was removed. Clips uploaded by earlier builds can still carry `audioAssessment.spokenLanguage`: either the uploader's choice (`status=confirmed`, `method=uploader`) or a `likely` language guessed on the uploader's phone before detection moved to the viewer. The app treats both as a declared language, which skips detection on every viewer's phone (no permission prompt, no download).

The API still accepts those shapes so older app versions keep working: `confirmed` needs a valid code and a client-supplied confidence is dropped, and the older `uploader_unsure` reason is accepted too. Like the rest of the assessment this is untrusted advisory metadata: it only selects the dubbing source language and never authorizes anything. A declared language we cannot dub from yet (anything but English and Spanish) means the audio button is not offered for that clip. Stored JSONB needs no migration.

## Listening language (viewer's language)

The goal is that a viewer can hear any clip in a language they understand, so the target is the viewer's, not a fixed Thai.

- **Choosing it.** Settings → Listening language lists the 22 languages Apple Translation can produce that also have a system speech voice; rows this iPhone cannot serve are disabled. "Automatic" (the default) uses the device's language list in order, skipping the language already spoken in the clip: a viewer who lists English then Thai hears Thai dubbing of an English clip and English dubbing of a Spanish clip. An explicit choice is stored in `UserDefaults` and always wins, except that a clip already spoken in that language is not dubbed. The audio-choice dialog also has "Change listening language…", which opens the same list and starts dubbing as soon as a language is chosen.
- **Entry points.** The feed's "Choose audio" button and the full-screen player's audio button appear when the clip has speech and dubbing could change what the viewer hears: its language is unknown (the viewer's iPhone will find out when asked), or known, supported and different from at least one language the viewer listens in. They are hidden for music, for a clip already in the viewer's language (declared, or detected earlier on this phone) and for a declared language we cannot dub from yet. A viewer whose device languages are all unsupported still gets the button, so they can choose a language. The dialog lists one "Listen in …" button per language the viewer listens in (except the clip's own), so for a clip of unknown language the viewer picks the target explicitly.
- **Pipeline.** Saved audio, else source language (declared on an older clip, remembered from an earlier detection, or detected now; English or Spanish for now) → Apple Translation into the listening language → the best installed system voice for that language (usual region first, then quality; novelty voices are skipped) → AAC upload to `dubbed-audio?lang=<code>`. If translation has no route between the two languages or no voice is installed, the player says so and keeps the original audio.
- **Language models.** Settings → Language models lists the translation pairs the viewer may need (each dubbing source into each possible listening language), not a fixed Thai pair.
- **Interface language.** Dubbing and settings text is localized (English and Thai; Thai is the only extra region in `Localizable.xcstrings`). Language names inside sentences follow the app's interface language rather than the region setting, so a sentence never mixes a third language. Other languages fall back to English.
- **Known gaps.** Source languages beyond English and Spanish are not routed yet. Detection can only name languages this iPhone can recognize, takes a few seconds plus the clip download on a cache miss, and treats the first non-silent stretch as representative (a music intro can defeat it). Chinese uses one entry (Mandarin) for both scripts. The cache is still first-write-wins for any signed-in viewer, so a bad upload would be heard by later viewers of that language; there is no report/removal flow yet.
