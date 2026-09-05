import '../models/note_document.dart';
import 'capabilities.dart';
import 'connection.dart';

/// Identifies a configured provider instance in settings and on stored notes.
class ProviderId {
  const ProviderId(this.value);
  final String value;

  @override
  bool operator ==(Object other) => other is ProviderId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Shared surface of both provider stages.
abstract class AiProvider {
  ProviderId get id;

  /// Shown in settings. "Claude", "Ollama (192.168.1.50)".
  String get displayName;

  ProviderCapabilities get capabilities;

  /// True when the endpoint is on the user's own network — changes timeouts, retry
  /// policy, and every diagnostic message the connection tester produces.
  bool get isLocalEndpoint => false;

  /// Round-trips to the provider and reports what happened. Must never throw.
  Future<ConnectionResult> test();
}

// ---------------------------------------------------------------------------
// Stage 1 — speech to text
// ---------------------------------------------------------------------------

/// One transcribed span of audio.
class TranscriptSegment {
  const TranscriptSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.speaker,
  });

  final int startMs;
  final int endMs;
  final String text;

  /// Diarization label, when the provider supplies one. Most do not.
  final String? speaker;

  TranscriptSegment shifted(int offsetMs) => TranscriptSegment(
        startMs: startMs + offsetMs,
        endMs: endMs + offsetMs,
        text: text,
        speaker: speaker,
      );
}

class TranscribeRequest {
  const TranscribeRequest({
    required this.audio,
    required this.mimeType,
    this.offsetMs = 0,
    this.languageHint,
    this.primingPrompt,
  });

  final List<int> audio;
  final String mimeType;

  /// Position of this chunk in the full recording. Every returned segment is shifted by
  /// this so timestamps stay absolute and `sourceRef` offsets remain meaningful.
  final int offsetMs;

  final String? languageHint;

  /// Tail of the previous chunk's transcript. Keeps proper nouns and technical vocabulary
  /// spelled consistently across chunk seams.
  final String? primingPrompt;
}

abstract class TranscriptionProvider extends AiProvider {
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request);
}

// ---------------------------------------------------------------------------
// Stage 2 — text to structure
// ---------------------------------------------------------------------------

class StructureRequest {
  const StructureRequest({
    required this.systemPrompt,
    required this.userContent,
    required this.schema,
    this.maxOutputTokens = 16000,
    this.priorTurns = const [],
  });

  final String systemPrompt;
  final String userContent;

  /// The canonical schema. Each adapter renders it into its own dialect.
  final Map<String, dynamic> schema;

  final int maxOutputTokens;

  /// Earlier turns, so the repair loop can send validation errors as a follow-up without
  /// re-uploading the transcript.
  final List<StructureTurn> priorTurns;
}

class StructureTurn {
  const StructureTurn(this.role, this.content);
  final String role; // 'user' | 'assistant'
  final String content;
}

/// What the model returned, before validation. Deliberately raw: the pipeline owns
/// parsing, validation and repair so every provider gets identical treatment.
class StructureResponse {
  const StructureResponse({
    required this.rawText,
    this.inputTokens,
    this.outputTokens,
    this.model,
  });

  final String rawText;
  final int? inputTokens;
  final int? outputTokens;
  final String? model;
}

abstract class StructuringProvider extends AiProvider {
  Future<StructureResponse> structure(StructureRequest request);
}

/// A structured note plus everything learned while producing it.
class StructureOutcome {
  const StructureOutcome({
    required this.document,
    required this.raw,
    this.repairAttempts = 0,
    this.unverifiedQuotes = const [],
    this.inputTokens,
    this.outputTokens,
  });

  final NoteDocument document;
  final Map<String, dynamic> raw;

  /// How many repair round-trips it took. Persisted, because a provider that needs
  /// repairs regularly is one the user should be told about.
  final int repairAttempts;

  /// Item ids whose `sourceRef.quote` could not be found in the transcript. Surfaced in
  /// the UI as unverified rather than silently trusted or silently dropped.
  final List<String> unverifiedQuotes;

  final int? inputTokens;
  final int? outputTokens;
}
