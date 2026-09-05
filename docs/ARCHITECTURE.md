# Transcript — Architecture & Build Plan

A cross-platform (iOS + Android) recorder that turns speech into structured, actionable notes
using **the user's own AI** — their API key, or their own machine on the LAN. No inference
runs on our servers, because we don't have any.

---

## 0. The constraint that shapes everything

**Transcription and structuring are two different jobs, and the providers do not overlap.**

Anthropic's API accepts text, images and PDFs — it has no audio input. Local LLMs served by
Ollama or LM Studio don't either; whisper.cpp is a separate model and a separate binary.
Gemini takes audio natively. OpenAI has Whisper and `gpt-4o-transcribe`.

So "pick your AI" cannot be one dropdown. It's a two-stage pipeline with two independent
provider slots:

```
 ┌──────────┐   audio    ┌────────────────────┐  text   ┌──────────────────┐  JSON  ┌────────┐
 │ Recorder │ ─────────► │  Speech-to-text    │ ──────► │  Structuring LLM │ ─────► │  Note  │
 └──────────┘            │                    │         │                  │        │ Doc    │
                         │ • on-device (free) │         │ • Claude         │        └────────┘
                         │ • whisper.cpp      │         │ • GPT            │            │
                         │ • Whisper API      │         │ • Gemini         │      ┌─────┴─────┐
                         │ • Gemini           │         │ • Ollama/LM Std  │      ▼           ▼
                         └────────────────────┘         └──────────────────┘   Kanban      Gantt
```

This split is a feature, not a workaround:

- The **default config needs no API key at all** — on-device STT (Apple `Speech` /
  Android `SpeechRecognizer`) plus a local Ollama endpoint gets a working app for free.
- Raw audio can stay on the phone while only *text* goes to a cloud LLM. That's a materially
  better privacy story than "upload your meetings," and it's a real differentiator against the
  incumbents.
- Users can mix: cheap local Whisper for transcription, Claude for the reasoning that actually
  benefits from a frontier model.

Everything downstream — the settings UI, the capability matrix, the cost meter — follows from
accepting that this is two pipelines, not one.

---

## 1. Tech stack

### 1.1 Framework: Flutter

**Recommendation: Flutter.** The deciding factor is the visualization requirement, not the
audio one.

Kanban and Gantt are custom interactive canvases — drag-and-drop cards across columns, pan/zoom
a timeline with dependency arrows, hit-test bars at 120 Hz. In Flutter that's `CustomPainter`
over a single rendering pipeline that is byte-identical on both platforms. In React Native
you either drive `react-native-skia` (which is essentially the same renderer, reached through
more layers) or embed a web charting library in a `WebView`, where pan/zoom gesture handling
against the native scroll view is a known source of jank.

Secondary reasons: Dart's sound null safety plus `freezed`/`json_serializable` gives real
compile-time safety over the LLM JSON boundary, which is where this app's bugs will live;
one toolchain; `dart:ffi` makes bundling whisper.cpp straightforward later.

**Choose React Native instead if** you have an existing TypeScript team, or you want to share
substantial code with a web app. Both are viable — the cost of the wrong choice here is weeks,
not the project.

**Not recommended for v1:** Kotlin Multiplatform + Compose Multiplatform. Best-in-class audio
integration, but iOS Compose and the charting ecosystem are still thin, and you'd be building
the Gantt renderer twice or writing it in Compose canvas anyway.

### 1.2 Libraries

| Concern | Package | Notes |
|---|---|---|
| Audio capture | `record` (^6) | PCM16 file **and** `startStream()`. Only package with clean streaming on both platforms. |
| Background recording | `flutter_foreground_task` (Android) + native `AVAudioSession` channel (iOS) | Not optional; see §2.4. |
| Waveform / levels | `audio_waveforms` | Live amplitude — the recording screen's only job is to prove it's listening. |
| Playback + scrub | `just_audio` | Position stream drives transcript highlighting. |
| On-device STT | `speech_to_text` | Wraps `SFSpeechRecognizer` / Android `SpeechRecognizer`. Free, no key. Caveats in §3.1. |
| Local Whisper | `whisper_ggml`, or `dart:ffi` → whisper.cpp | True offline. +40–150 MB per model. Phase 5. |
| HTTP | `dio` | Interceptors, `CancelToken`, streamed responses, per-provider retry policy. |
| Secure key storage | `flutter_secure_storage` | Keychain (`first_unlock_this_device`) / Android Keystore + EncryptedSharedPreferences. |
| Database | `drift` (SQLite) | Chosen over Isar: the task/board/timeline queries are relational and date-ranged, and the chunk queue wants transactions. |
| State | `riverpod` (^2) | `AsyncNotifier` maps cleanly onto the pipeline's states; trivially fakeable providers for tests. |
| Models / JSON | hand-written in `transcript_core`; `freezed` in the app layer | The core package stays dependency-free and codegen-free so CI runs it in seconds; a sync test round-trips a fixture through both the validator and the classes so the two cannot drift. |
| Schema validation | built into `transcript_core` | A deliberately small validator covering the subset the canonical schema uses; it fails loudly on any keyword it does not recognise rather than passing it silently. |
| Charts (simple) | `fl_chart` | Sparklines, cost/usage graphs. |
| Kanban | `appflowy_board` | Real drag-drop between columns, actively maintained. |
| Gantt | **custom `CustomPainter`** | Evaluate `syncfusion_flutter_charts` RangeBarSeries first, but the explicit/inferred/absent rendering in §5 is app-specific enough to justify owning it. |
| LAN discovery | `multicast_dns` | Finds Ollama at `_http._tcp`; always keep manual IP entry as the fallback. |
| Export | `csv`, `share_plus`, `icalendar` | Markdown, Jira CSV, .ics. |

### 1.3 Two platform gotchas that will cost you a day each

**Local LLM connections are blocked by default on both platforms.** Talking to
`http://192.168.1.50:11434` requires:

- **iOS** — an ATS exception (`NSAllowsLocalNetworking`) *and* `NSLocalNetworkUsageDescription`.
  Since iOS 14, LAN access needs explicit user consent; without the plist key the request fails
  silently with a generic connection error, which is maddening to debug.
- **Android** — a `network_security_config.xml` permitting cleartext for private ranges only
  (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), not a blanket `usesCleartextTraffic=true`.

Build the connection tester in Phase 0 so these surface immediately rather than in Phase 5.

**Background audio is the highest-risk platform work in the app.** iOS needs the `audio`
background mode plus correct `AVAudioSession` category and interruption handling (phone calls,
Siri, other apps stealing the session). Android needs a foreground service with a persistent
notification, and on Android 14+ the `microphone` foreground service type must be declared and
justified at review. Budget real time for this; it is where cross-platform frameworks leak.

---

## 2. System architecture

### 2.0 Repository layout

```
packages/transcript_core/   pure Dart, zero runtime dependencies, no Flutter
  schema/                   canonical schema + provider dialects + validator
  models/                   NoteDocument and friends
  providers/                HttpTransport seam, capabilities, adapters
  pipeline/                 chunk planner, transcript assembly, structuring, verification
app/                        Flutter: UI, secure storage, drift, platform channels
docs/                       this file, the schema, the prompt library
```

The split is deliberate. Everything that decides whether the app is *correct* — request
shaping for five providers, schema dialects, chunk boundaries, overlap dedup, the repair
loop, quote verification — lives in a package with no HTTP client, no Flutter, and no I/O.
Adapters take an injected [`HttpTransport`], so the full request and response path of every
provider is unit-testable with no network, no device, and no API key. The Flutter app owns
the UI, the keychain, the database and the platform channels, and nothing else.

### 2.1 Layers

```
UI            Flutter widgets · CustomPainter canvases
  ↕ Riverpod
Domain        Recording · Transcript · NoteDocument · Task · Board · Timeline
  ↕
Services      RecorderService ──► ChunkPipeline ──► TranscriptionProvider ┐
                                                                          ├─► Validator ─► Repair
                                  NoteAssembler  ──► StructuringProvider  ┘
              CostMeter · ExportService · ConnectionTester
  ↕
Storage       drift (SQLite, SQLCipher)  ·  secure storage (keys only)  ·  encrypted file store (audio)
```

Providers are behind two interfaces, deliberately separate:

```dart
abstract class TranscriptionProvider {
  ProviderCapabilities get capabilities;
  Future<ConnectionResult> test();
  Stream<TranscriptSegment> transcribe(AudioChunk chunk, TranscribeOptions o);
}

abstract class StructuringProvider {
  ProviderCapabilities get capabilities;
  Future<ConnectionResult> test();
  Future<RawJsonResult> structure(String prompt, JsonSchema schema, StructureOptions o);
}

class ProviderCapabilities {
  final bool acceptsAudio, nativeJsonSchema, diarization, streaming;
  final int maxRequestBytes, contextWindowTokens;
  final Set<String> languages;
}
```

`ProviderCapabilities` is not decoration — it drives the settings UI (grey out diarization when
the provider can't do it), the chunk sizer (`maxRequestBytes`), and the map/reduce decision
(`contextWindowTokens`). Adding a provider should mean adding one adapter and one row, nothing else.

### 2.2 Capability matrix

| Provider | Audio in | Text in | Native JSON schema | Key notes |
|---|---|---|---|---|
| **Anthropic Claude** | ✗ | ✓ | ✓ `output_config.format` | Structuring only. Best at the "don't invent tasks" instruction-following this app lives on. |
| **OpenAI** | ✓ Whisper / `gpt-4o-transcribe` | ✓ | ✓ `json_schema`, `strict: true` | 25 MB per transcription request — the hard cap that sets chunk size. |
| **Google Gemini** | ✓ native | ✓ | ✓ `responseSchema` | Only provider that can do both stages in one call. Inline audio under ~20 MB, else Files API. |
| **Ollama** | ✗ | ✓ | ✓ `format: <schema>` | `/api/chat` or OpenAI-compatible `/v1`. Context window is the real limit — see §4.5. |
| **LM Studio** | ✗ | ✓ | ✓ OpenAI-compatible | `:1234/v1`. |
| **On-device STT** | ✓ | — | — | Free, offline, no diarization, and iOS caps utterances at ~60 s. |
| **whisper.cpp (bundled)** | ✓ | — | — | Fully offline, word timestamps, no per-minute cost. |

### 2.3 Audio format

Record **16 kHz mono PCM16** as the canonical working format. Every STT engine resamples to
16 kHz internally; feeding it 44.1 kHz stereo triples upload size for zero accuracy gain.
Keep a compressed copy (Opus ~24 kbps, ≈180 KB/min) for playback and retention; discard the
PCM once every chunk reaches a terminal state.

An hour of meeting is ≈115 MB PCM, ≈11 MB Opus, ≈9–10k words, ≈13k tokens.

### 2.4 The chunk pipeline

Chunking is the heart of the reliability story, and it exists for three independent reasons:
provider request limits, failure isolation, and letting transcription overlap with recording
so results feel immediate.

**Chunk boundaries are voice-activity-aligned, never fixed.** A hard 30-second cut lands
mid-word roughly every time. Run a cheap energy-based VAD over the incoming PCM and cut at a
silence of ≥400 ms, subject to:

```
target chunk      45 s
min chunk         15 s   (don't fragment fast dialogue)
max chunk        600 s   (hard cut if nobody stops talking)
max bytes        min(provider.maxRequestBytes, 20 MB) with headroom
overlap            3 s   carried into the next chunk
```

**The 3-second overlap is deduplicated on reassembly**, by fuzzy-matching the tail of chunk *n*
against the head of chunk *n+1* on normalized tokens and splicing at the best alignment. Without
overlap you drop words at every seam; without dedup you double them.

**Each chunk also carries the last ~200 characters of the previous chunk's transcript as a
priming prompt** (Whisper's `prompt` parameter, and equivalents). This keeps proper nouns and
technical vocabulary spelled consistently across seams — otherwise "Kubernetes" becomes
"Cooper Netties" in chunk 4 and the note reads like nonsense.

**Chunks are rows in SQLite, not objects in memory:**

```
chunks(id, recording_id, index, start_ms, end_ms, path, bytes,
       state, attempts, next_attempt_at, provider_id, text, error)

state: pending → uploading → transcribed
                     ↓ (retryable)
                  backoff → uploading
                     ↓ (terminal)
                   failed
```

That table is the whole durability story. The app is killed by the OS, the network drops, the
battery dies mid-meeting — on relaunch the pipeline resumes from the queue and only re-uploads
what didn't finish. Retries use exponential backoff with jitter; 429s honour `Retry-After`;
concurrency is capped at 2–3 in flight so a long recording doesn't trip rate limits.

**A single failed chunk must not fail the recording.** Mark it, splice a
`[unintelligible 12:30–13:15]` marker into the transcript, structure everything else, and let
the user retry that chunk alone.

### 2.5 Assembly and structuring

Once chunks are transcribed, assemble a timestamped transcript, then decide the structuring
strategy by token budget:

```
budget = provider.contextWindowTokens − systemPromptTokens − schemaTokens − reserveForOutput

transcriptTokens ≤ budget  →  single pass
transcriptTokens >  budget →  map / reduce
```

Map/reduce splits on **topic and speaker-turn boundaries**, not arbitrary token counts —
splitting mid-discussion produces half-formed action items on both sides of the seam. Each
window carries the running participant roster so speaker identity survives across windows, and
absolute timestamps so `sourceRef` offsets stay meaningful. The reduce pass merges duplicates,
unions dependencies and regenerates the summary. Prompts for all three passes are in
[`prompts/structuring.md`](prompts/structuring.md).

### 2.6 The JSON reliability layer

Never trust the model's JSON. In order:

1. **Use native structured output** where the provider has it — Claude's `output_config.format`,
   OpenAI's `strict: true` `json_schema`, Gemini's `responseSchema`, Ollama's `format`. This
   converts most failures from runtime bugs into non-events.
2. **Tolerant parse** — strip markdown fences, trailing commas, and leading prose.
3. **Validate** against the canonical schema.
4. **Repair loop** — on failure, send the validation errors back on the same conversation and
   ask for a corrected object (§4 of the prompts doc). Cap at 2 attempts.
5. **Verify quotes offline** — fuzzy-match every `sourceRef.quote` against the transcript.
   Items that don't match get flagged in the UI as unverified. This is a cheap, deterministic,
   zero-cost hallucination check and it catches the failure mode that matters most.
6. **Degrade, never lose** — if structuring fails entirely, the raw transcript is already saved
   and the user still has their recording. Offer a retry with a different provider.

One canonical schema lives in [`schemas/note-document.schema.json`](schemas/note-document.schema.json),
and per-provider **dialects are generated from it** at runtime — OpenAI strict mode requires
every property in `required` and `additionalProperties: false`; Gemini's `responseSchema`
doesn't support `$ref`; Ollama passes plain JSON Schema. Author once, emit three ways. Never
maintain parallel copies.

### 2.7 Security

- API keys live **only** in Keychain / Keystore via `flutter_secure_storage`. Never in the
  database, never in logs, redacted in crash reports. Show them masked after entry.
- The device talks **directly** to the user's chosen endpoint. There is no backend, so there is
  no server-side key custody and no place for us to leak recordings from. State this plainly in
  onboarding — it's the app's strongest claim.
- Audio and transcripts encrypted at rest (SQLCipher + platform file protection).
- Consent: recording law varies by jurisdiction (all-party consent in several US states, the
  EU, and elsewhere). Ship a first-run disclosure and an optional recording indicator tone. This
  is a product requirement, not a legal opinion — get counsel before launch.
- The cost meter is a trust feature: a running per-recording estimate of tokens and dollars,
  because BYOK users are spending their own money and will not tolerate surprise bills.

---

## 3. Prompt engineering

Full prompt library: **[`prompts/structuring.md`](prompts/structuring.md)**.
Canonical schema: **[`schemas/note-document.schema.json`](schemas/note-document.schema.json)**.

The important insight is architectural rather than literary: **the schema does most of the work,
and prompt wording does less than you'd expect.** Prompt text behaves differently across
providers and drifts between model versions. A required enum does not.

Three schema decisions carry the reliability:

**`dateBasis: explicit | inferred | absent`** — required on every task. This is the single most
important field in the app. A meeting produces a handful of real dates and a lot of vague
intent; a model asked for `dueDate` alone will quietly manufacture plausible dates for
everything, and you get a Gantt chart that looks authoritative and is fiction. Forcing the model
to *declare* which kind of date it has moves the uncertainty into a value the UI can render
honestly — solid bars for explicit, hatched ghost bars for inferred, and a "needs dates" tray for
absent, which the user drags onto the timeline themselves.

**Required `sourceRef` with a verbatim `quote`** — every extracted item must cite a real span of
transcript. This makes fabrication *more* effortful than accuracy, which is the only reliable way
to suppress it, and it's independently verifiable in code (§2.6 step 5). It also gives the UI
tap-an-item-to-play-the-moment for free, which is the feature users end up loving most.

**`dependsOn` empty by default** — populated only for blocking relationships stated aloud. Models
will happily infer a dependency graph from the order topics were discussed. A hallucinated
critical path is worse than no critical path.

Everything else — imperative task titles, don't-assign-unowned-work, merge restated commitments,
correct STT mishearings into `aliases` — is ordinary prompt hygiene, and it's in the doc.

**One more architectural note:** the Kanban board and Gantt chart do **not** need their own LLM
call. Columns are `groupBy(status)`; the timeline is a date-range projection of the same tasks.
Spending a second inference on what a `groupBy` does is cost, latency and a fresh opportunity to
hallucinate. The only place a second call earns its keep is the *optional, user-invoked* sprint
planner (§5 of the prompts doc) — the one feature allowed to propose things not in the audio, and
therefore the one whose output is visibly labelled "suggested".

---

## 4. Roadmap

Estimates assume one experienced Flutter developer. Halve the elapsed time with two.

### Phase 0 — Foundations · 1–2 weeks
Repo, CI (analyze/test/build both platforms), models mirroring the canonical schema, both
provider interfaces with fake implementations, secure storage, drift schema, settings UI,
and — critically — **the connection tester**: enter a key or a LAN address, hit Test, see a
real round-trip result. Shipping the ATS/cleartext/local-network plumbing in week one turns
Phase 5's worst surprise into a Phase 0 chore.

*Done when:* no user-facing feature exists, but you can prove connectivity to Claude, OpenAI,
Gemini and a laptop running Ollama from a physical device on both platforms.

### Phase 1 — MVP · 3–4 weeks
Record → transcribe → structure → read. One provider per slot to start (on-device STT +
Claude), then fill in the rest behind the interfaces. Recording screen with live waveform,
transcript view, notes view with bullets and action items, local library, playback with
transcript highlighting. Batch mode only, short recordings only, no chunk queue yet.

*Done when:* you record a 10-minute conversation and get notes you'd actually keep.

### Phase 2 — Make it survive reality · 2–3 weeks
The phase that decides whether this is a demo or a product. Chunk queue with VAD boundaries,
overlap dedup and resumable retries. Background and lock-screen recording. Map/reduce for long
transcripts. JSON repair loop and offline quote verification. Cost meter. Interruption handling.
Test against a 90-minute recording with the network cycling on and off.

*Done when:* a two-hour meeting on flaky wifi with the app backgrounded produces complete notes.

### Phase 3 — Kanban · 2–3 weeks
Board view over `tasks`, drag-and-drop between columns persisting back to the note document,
inline editing, assignee and priority filters, the "needs dates" tray, and a per-item link back
to its transcript moment. Manual task creation, because every extraction misses something.

*Done when:* a user can run a standup off the board without opening the transcript.

### Phase 4 — Timeline / Gantt · 2 weeks
Custom-painted timeline: milestone markers from `timelineAnchors`, task bars styled by
`dateBasis` (solid / hatched / absent), dependency arrows for stated dependencies only, pinch-zoom
across day/week/month scales, drag a bar to set dates (which promotes it to user-confirmed).
Optional sprint-planner call. Export to CSV, Markdown, .ics, Jira CSV.

*Done when:* the chart tells the truth about what's known and what's guessed.

### Phase 5 — Local & offline · 2–3 weeks
Ollama and LM Studio adapters with mDNS discovery and manual entry, context-window-aware
chunking with an honest warning when a small local model can't take the whole transcript,
model picker, and bundled whisper.cpp for genuinely offline end-to-end operation.

*Done when:* the app works in airplane mode with zero API keys configured.

### Phase 6 — Ship · 2–3 weeks
Onboarding that explains BYOK without scaring people, privacy nutrition labels (declare no data
collection — you genuinely collect none), microphone and foreground-service justifications for
review, consent disclosure, crash reporting with key redaction, accessibility pass, and beta.

**Total: roughly 13–20 weeks to a credible v1.**

### Sequencing notes

Phase 2 before Phase 3 is the call worth defending. Boards are the fun part and the demo-able
part, and there will be pressure to build them first. But a beautiful Kanban populated from a
recording that silently truncated at minute twelve is worse than no product — and chunking is
the kind of infrastructure that gets exponentially harder to retrofit once views depend on the
data shape. Earn the visualizations.

---

## 5. Risks

| Risk | Mitigation |
|---|---|
| **Fabricated tasks reach a board and get acted on** | Required `sourceRef` quotes; offline quote verification; unverified items visibly flagged. The whole §3 design. |
| **Gantt implies precision that doesn't exist** | `dateBasis` rendered honestly; absent-date tasks never auto-placed. |
| Background recording breaks on an OS update | Integration tests on physical devices per OS release; recording is the one thing that must never fail. |
| App Store review on microphone + foreground service | Clear justification strings; BYOK means no data-collection disclosures to defend. |
| Small local models can't hold a long transcript | Context-aware map/reduce; honest pre-flight warning; recommend minimum model sizes. |
| Diarization gap (users want "who said what") | On-device STT can't. Set expectations; consider `pyannote`-class on-device diarization post-v1. |
| BYOK limits monetization | One-time purchase or pro tier for boards/exports/sync — not per-inference, since inference isn't ours to bill. |

## 6. Open decisions

1. **Diarization in v1?** It's the most-requested feature in this category and the most expensive
   to deliver well. Recommend: no for v1, design `participants[]` so it slots in.
2. **Cloud sync?** A backend contradicts the privacy story. Recommend: end-to-end-encrypted
   CloudKit/Drive sync of the user's own storage, never our servers.
3. **Team features?** Sharing a board implies a backend and changes the product. Defer.
4. **Which is the flagship default** — free (on-device + local) or best (Whisper + Claude)?
   Recommend defaulting to free, with a one-tap upgrade path, because "works before you've
   pasted a key" is the strongest onboarding this app can have.
