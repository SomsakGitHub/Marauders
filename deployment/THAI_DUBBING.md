# Thai audio on the viewer's iPhone

The viewer explicitly selects original audio or Thai audio. Ordinary playback never starts translation. No ElevenLabs credentials, dubbing server endpoint, migration, or deployment is required.

The app uses Apple's on-device English speech recognition (`requiresOnDeviceRecognition`), Translation with the low-latency strategy, and the installed Thai speech voice. The system asks for speech permission and may offer language-model downloads. Unsupported devices/language pairs, denied permissions, and failures retain original playback. UI tests never trigger real speech permissions or translation.

Trial scope: English speech, up to 120 seconds and 12 MiB. The selected clip is downloaded for local audio extraction. Temporary files are removed when the viewer closes or selects original. Going into the background cancels processing. No clip audio or transcript is sent to an AI provider.

This first implementation translates the full transcript into a single Thai narration, using a standard Thai system voice. It restarts the video when switching to Thai. It does not preserve speaker identity, background sound, or sentence-level timing. Narration longer than the video is compressed to fit; shorter narration leaves silence afterward. Quality and processing time must be verified with an actual English clip on a compatible iPhone. This is not equivalent to a professionally synchronized dub.

To test: open an English clip, select Thai, allow speech recognition and any language download, then verify Thai speech, seeking, looping, closing, background cancellation, and switching to original. Check unsupported/denied cases. Automated tests cover file finalization, late callbacks after cancellation, original-state reset, and the unavailable UI path, rather than proving speech/translation model quality.

## Device verification (24 October 2026)

A known English speech sample was synthesized, transcribed with on-device recognition, translated with the installed English–Thai model, and rendered into a readable Thai audio file (about 9.6 seconds) on iPhone 16 Pro Max. This validates local processing, not translation quality across arbitrary clips or sentence timing. A real map clip downloaded and extracted successfully but did not yield an English transcript; original playback remained available. Native speech callbacks explicitly use Sendable closures to avoid Swift actor-isolation crashes. Permission dialogs pause playback without canceling the translation; entering the background cancels processing. Temporary live-device probes are removed from the normal automated suite.

## Amsterdam clip follow-up

The exact Amsterdam database clip was tested on the iPhone separately from the nearby Bangkok map pin. The previous full-file transcription waited until timeout. Audio is now decoded to 16 kHz, 16-bit mono PCM WAV and split into 20-second requests. A later request returning Apple's “No speech detected” is treated as an empty segment rather than discarding earlier recognized speech. Digital-silence segments are skipped; if every segment is empty the original-only fallback remains. The exact Amsterdam clip produced a readable Thai narration file of about 22.6 seconds. The observed end-to-end trial still took about 75 seconds, including waiting for the no-speech segment, so latency remains a limitation. A stereo-to-mono regression test verifies that splitting preserves total audio duration.
