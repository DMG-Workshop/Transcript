# Transcript

A cross-platform (iOS + Android) recorder that turns speech into structured, actionable
notes — bulleted summaries, action items, Kanban boards and timelines — using **your own AI**.

Bring your own API key (Anthropic, OpenAI, Google), or point the app at a local model
running on your own machine via Ollama or LM Studio. There is no backend: the device talks
directly to the endpoint you choose, so your recordings never pass through our servers.
With on-device speech recognition and a local LLM, the app works with no API key and no
network at all.

## Status

Pre-implementation. The architecture and build plan are complete.

## Documentation

| Document | What's in it |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Stack choice, system design, audio chunking pipeline, provider abstraction, roadmap |
| [`docs/schemas/note-document.schema.json`](docs/schemas/note-document.schema.json) | The canonical `NoteDocument` schema every provider fills |
| [`docs/prompts/structuring.md`](docs/prompts/structuring.md) | Production prompts: extraction, map/reduce, schema repair, sprint planning |

## The shape of it

```
 Recorder ──► Speech-to-text ──► Structuring LLM ──► NoteDocument ──► Notes · Kanban · Timeline
              on-device (free)    Claude / GPT /
              whisper.cpp         Gemini / Ollama
              Whisper · Gemini
```

Transcription and structuring are separate provider slots, because the providers don't
overlap — Claude and Ollama take no audio, on-device speech recognition does no reasoning.
Keeping them independent is what lets audio stay on the phone while only text reaches a
cloud model.

## Repository layout

```
packages/transcript_core/   pure Dart · zero runtime dependencies · no Flutter
app/                        Flutter app · UI, keychain, database, platform channels
docs/                       architecture, canonical schema, prompt library
```

Everything that decides whether the app is *correct* — request shaping for five providers,
schema dialects, chunk boundaries, overlap dedup, the repair loop, quote verification —
lives in `transcript_core`, which has no HTTP client and no Flutter. Adapters take an
injected transport, so every provider's full request and response path is unit-testable
with no network, no device, and no API key.

## Working on it

```bash
# Core: analyze and test in seconds, no Flutter toolchain needed
cd packages/transcript_core && dart pub get && dart test

# Regenerate docs/schemas/note-document.schema.json from the Dart source of truth
dart run tool/export_schema.dart

# App: drift needs codegen before analyze will pass
cd app && flutter pub get && dart run build_runner build --delete-conflicting-outputs
flutter run
```

## Status

**Phase 6 — ship.** 422 tests, all green.

| | |
|---|---|
| `transcript_core` | 301 tests. Everything from earlier phases plus **redaction** (keys, tokens, home directories and addresses stripped from anything durable), **local crash reports**, and a **privacy disclosure** that is the single source of truth for the app, the docs and the store answers. |
| `app` | 117 tests. Everything from earlier phases plus **onboarding** that explains BYOK without opening with a key request, a **privacy screen**, crash handlers wired through the redactor, and an **accessibility pass** over the recording flow. |
| `transcript_whisper_native` | 4 tests, run against a real compiled library. Vendors ggml/whisper.cpp behind a minimal FFI shim — no ffmpeg, since the app already produces exactly the WAV the decoder wants. |

Offline transcription now runs for real: a downloaded Whisper model decodes on the
device through `dart:ffi`, with the model picker and resumable, integrity-checked
download in front of it.

Crash reports are written to a file **on the device and are never uploaded** — which is
what lets the store listing say "collects no data" with nothing to qualify, and means
the user reads a report before deciding to send it. Every key the app holds is
registered with a redactor by the key store itself, so no call site can forget.
[docs/PRIVACY.md](docs/PRIVACY.md) is generated from the same disclosure the app
renders, and CI fails if the two drift.

`WhisperCatalog` now carries the real, verified SHA-256 for every model — this sandbox
cannot reach Hugging Face to compute them directly, so that ran as a one-off GitHub
Actions job instead. It also caught a real bug: the download org was `ggml-org/whisper.cpp`,
which 401s, instead of the actual `ggerganov/whisper.cpp`.

**Still needs real hardware:** background recording across an OS interruption, the audio
session, and on-device decode speed. See [docs/STORE_READINESS.md](docs/STORE_READINESS.md)
for the release checklist.

## Repository layout