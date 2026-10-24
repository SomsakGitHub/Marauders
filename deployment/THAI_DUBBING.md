# Optional Thai AI narration with a shared server cache

The viewer explicitly chooses original or Thai AI audio. Original playback never requests Thai processing. The app checks for a reusable server audio file before creating a TranslationSession. A cache hit needs neither local speech permission nor translation models. On a miss, speech recognition, English–Thai translation and Thai narration run on the viewer's iPhone.

Completed narration is compressed to AAC/M4A and uploaded to the existing R2 video bucket. Sharing is automatic, with an AI-translation label and original-audio choice; it does not claim endorsement by the clip owner. No paid AI provider, API key, new database table, Worker or bucket is required. Only the existing Worker is updated.

## Cache contract

- GET `/v1/videos/:id/thai-audio?source=<sha256-of-source-url>` returns `missing` or `ready` plus an audio URL. Guests can read cached audio for public clips; a supplied invalid session is rejected.
- POST the same path requires a signed-in session, raw `audio/mp4` body, and `X-Source-SHA256`. Maximum: 4 MiB and 180 seconds of structurally valid audio-only AAC. Existing database-backed per-user rate limits apply.
- Immutable R2 key: `translations/<clip-id>/<source-url-sha256>-th-v1.m4a`. Changed clip sources get a different key. Conditional `If-None-Match: *` writes preserve the first completed file when viewers upload concurrently.
- Successful clip deletion cleans all translation keys for that clip. Uploads recheck the source after writing to handle concurrent deletion or source changes.

The server validates MP4 box bounds, movie duration, audio handlers and AAC sample entries, not translation meaning. Two simultaneous first viewers can still both generate locally; once one upload completes, later viewers reuse it. Upload failure leaves local listening available. The upload retains bounded compressed data after the player closes, but terminating the app can interrupt an unfinished transfer.

## Local processing and limitations

Trial input: English speech, up to 120 seconds and 12 MiB. Audio is decoded to 16 kHz mono PCM WAV in 20-second segments. Digital silence is omitted. A no-speech segment does not discard words from earlier segments. If all segments are empty, original playback stays available. First use may require system language downloads and speech permission. Backgrounding cancels local processing; leaving or choosing original cleans local media.

The system Thai voice reads one combined translation. It does not preserve speaker identity, background audio or sentence timing. Thai playback restarts the video; longer narration is compressed to fit and shorter narration leaves silence. Words at segment boundaries can be imperfect.

## Verification

The exact Amsterdam clip produced about 22.6 seconds of Thai narration on iPhone 16 Pro Max. The uncached trial took about 75 seconds, including waiting for a no-speech segment. Backend checks cover shared reuse across sessions, concurrent conditional writes, source revisions, malformed/oversized/non-AAC audio and scoped deletion. iOS checks cover revision-bound URLs, authenticated upload, late-result cancellation and a cache hit without constructing a TranslationSession. The existing Worker was deployed and the real Amsterdam narration was uploaded through the signed-in iPhone session. A separate guest client downloaded the shared audio, verified its duration, and a fresh view model reused it without creating a TranslationSession (about 1.2 seconds for the measured lookup and media preparation). The first uncached conversion still has the longer local-processing cost. Temporary live probes are removed from the normal suite.

## Internal upload audio classification

The final exported MP4 is inspected on the iPhone before upload, off the main actor. Up to three one-second windows (start, middle, end) feed Apple's built-in SoundAnalysis classifier. A three-second sampling-work budget, cancellation, decoding failure or unsupported input returns an unknown advisory and never blocks upload. Classification is sampled evidence, not proof about the entire clip or a guarantee that recognition/translation will succeed. Speech and music can coexist. Singing/choir/rapping count as music evidence. Threshold policy: speech >= 0.5, mixed when music also >= 0.5; music only when music >= 0.7 and speech < 0.2; otherwise unknown. These are heuristic scores, not calibrated probabilities.

Language is a sanitized audio-track metadata hint, not language recognition. Missing metadata remains unknown. No speech permissions, downloaded translation models or paid AI calls are needed for classification. The existing 120-second/12-MiB local-translation limit is advisory; upload limits are unchanged. No diagnostic summary appears on the upload screen. Resetting/changing the selection discards stale results.

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
