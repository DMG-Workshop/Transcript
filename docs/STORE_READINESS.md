# Store readiness

What a release needs beyond a green build: the answers reviewers ask for, the
justifications for the two permissions that get apps rejected, and the checks to run
before a build goes out.

Privacy answers are **not** here — they are generated into [PRIVACY.md](PRIVACY.md) from
`packages/transcript_core/lib/src/privacy/disclosure.dart`, which is also what the app's
own privacy screen renders. Copy them from there so the listing, the app and the code
cannot disagree.

## Review notes

Paste into App Review Notes / the Play Console review comments.

> Transcript records audio and turns it into structured notes. It has no backend and no
> accounts: the user supplies their own AI, either the phone's built-in speech
> recognition, a Whisper model downloaded to the device, a model running on their own
> computer, or an API key for a service they already pay for.
>
> **No demo account is needed and no API key is required to review the app.** On first
> launch it is configured for on-device speech recognition, which is free, offline and
> needs no credentials. Record anything, stop, and the full flow — transcript, summary,
> action items, board, timeline, export — runs without any configuration.
>
> Microphone: the app's only function is recording speech; the prompt appears when the
> user taps record.
>
> Background audio (iOS) / foreground microphone service (Android): meetings and lectures
> run long and the screen locks. Without it the audio session is torn down mid-recording
> and the user loses the part of the meeting they cared about. Recording only ever starts
> from an explicit user action, and the Android notification stays visible for its whole
> duration.
>
> Local network (iOS): only used when the user configures a model server on their own
> machine (Ollama or LM Studio). It is not used to discover anything else, and the app
> functions fully without granting it.

### If review asks about the AI services

The app never talks to a provider the user has not configured with their own credentials.
No key ships in the binary, there is no default cloud provider, and a fresh install
performs no network request until the user chooses one and enters a key.

## Permissions, and why each exists

| Permission | Platform | Why | What breaks without it |
|---|---|---|---|
| `NSMicrophoneUsageDescription` / `RECORD_AUDIO` | both | The recording itself | Nothing works |
| `UIBackgroundModes: audio` | iOS | Keep capturing with the screen locked | Recording dies mid-meeting |
| `FOREGROUND_SERVICE_MICROPHONE` | Android 14+ | Same, and required by the platform to hold the mic in a service | Service cannot start |
| `POST_NOTIFICATIONS` | Android 13+ | The ongoing-recording notification the foreground service requires | Service cannot start |
| `NSSpeechRecognitionUsageDescription` | iOS | On-device recognition, the zero-config default | Default transcription path unavailable |
| `NSLocalNetworkUsageDescription` + Bonjour | iOS | Reaching Ollama / LM Studio on the user's own machine | LAN requests fail with a generic error and **no prompt is ever shown** |
| `NSAllowsLocalNetworking` | iOS | Plain HTTP to a local model server only | Local servers unreachable |

`NSAllowsLocalNetworking` is deliberately narrow: a blanket `NSAllowsArbitraryLoads`
would cover cloud providers too, and every cloud provider here is HTTPS.

## Before a release build

- [x] `WhisperCatalog.verified` is true — real SHA-256 hashes, verified by downloading
      each model and hashing it directly. (`packages/transcript_core/lib/src/whisper/whisper_models.dart`)
      Also fixed the download org while confirming this: `ggml-org/whisper.cpp` 401s —
      there is no such repo — the real one, matching whisper.cpp's own
      `download-ggml-model.sh`, is `ggerganov/whisper.cpp`.
- [ ] Version and build number bumped in `app/pubspec.yaml`; crash reports carry it.
- [ ] `dart run tool/export_privacy.dart` produces no diff — the listing matches the code.
- [ ] CI green on all five jobs, including the native whisper build.
- [ ] Record → notes → board → export, on a physical device of each platform. The
      simulator does not exercise the audio session, which is the part that breaks.
- [ ] Lock the screen mid-recording and confirm capture continues on both platforms.
- [ ] Take a phone call mid-recording and confirm the interruption banner appears and
      capture resumes.
- [ ] VoiceOver / TalkBack pass over record, note, board and settings.
- [ ] Run once with no provider configured and confirm nothing leaves the device.

## Beta

TestFlight and Play internal testing, with the same build. What to ask testers for:

1. A long recording — an hour or more. Chunking, resume-after-kill and the context-window
   warning only show their edges at length.
2. A recording interrupted by a call or another audio app.
3. One run on each provider they have access to, including a local server if they have one.
4. Whether the notes are *worth acting on* — the quality question no test can answer.

Crash reports stay on the device, so a tester has to send one deliberately: Settings →
Privacy → Crash reports → Share. Say so in the tester notes, because no other app works
this way and nobody will think to look.
