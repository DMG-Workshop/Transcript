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
