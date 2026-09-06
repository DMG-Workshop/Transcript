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

**Phase 5 — local and offline.** 363 tests, all green.

| | |
|---|---|
| `transcript_core` | 273 tests. Everything from earlier phases plus **LAN discovery** of Ollama/LM Studio, a **data-posture** describer, and the **whisper.cpp** offline core (model catalog, resumable verified downloader, provider seam). |
| `app` | 90 tests. Everything from earlier phases plus a **network-discovery sheet**, a **model picker**, a **privacy posture header** that states what the current pairing does with a recording, and a **filesystem model store**. |

Local structuring on Ollama or LM Studio is now discoverable, selectable and dated for
capacity (a small context window is called out before a long recording, not after).
The settings screen states, in plain terms, whether a recording stays on the phone,
stays on your network, or is sent to a service — and refuses to claim privacy it has
not earned.

**Not done in Phase 5:** whisper.cpp's *native* decode binding (the FFI call into the
ggml library) and its download UI screen. The catalog, resumable download, integrity
check and filesystem store are built and tested; the one genuinely-native, genuinely-
unverifiable piece — decoding PCM in the ggml library over FFI — is behind a
`WhisperEngine` seam and is the remaining work. It, and everything device-dependent,
still needs real hardware.

## Repository layout