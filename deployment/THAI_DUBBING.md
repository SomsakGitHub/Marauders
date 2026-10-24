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
