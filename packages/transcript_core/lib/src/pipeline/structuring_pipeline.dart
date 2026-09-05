import 'dart:convert';

import '../models/note_document.dart';
import '../prompts/structuring_prompts.dart';
import '../providers/provider.dart';
import '../schema/note_schema.dart';
import '../schema/validator.dart';
import 'json_extract.dart';
import 'quote_verifier.dart';
import 'transcript.dart';

/// Turns a transcript into a validated [NoteDocument].
///
/// Every provider gets identical treatment here — tolerant parse, schema validation,
/// bounded repair, offline quote verification — so reliability does not depend on which
/// model the user happened to configure.
class StructuringPipeline {
  StructuringPipeline({
    required this.provider,
    this.maxRepairAttempts = 2,
    Map<String, dynamic>? schema,
  })  : schema = schema ?? noteDocumentSchema,
        _validator = SchemaValidator(schema ?? noteDocumentSchema);

  final StructuringProvider provider;

  /// Two attempts, then degrade. A model that cannot satisfy the schema in three tries
  /// will not satisfy it in five, and the user is waiting.
  final int maxRepairAttempts;

  final Map<String, dynamic> schema;
  final SchemaValidator _validator;

  Future<StructureOutcome> run({
    required Transcript transcript,
    required String referenceDate,
    required String timeZone,
    required String sttProviderName,
    bool diarizationAvailable = false,
    String? userContext,
  }) async {
    if (transcript.isEmpty) {
      throw const StructuringException(
        'The transcript is empty. Nothing was said, or transcription failed for every '
        'chunk.',
      );
    }

    final systemPrompt = StructuringPrompts.system(
      referenceDate: referenceDate,
      timeZone: timeZone,
      durationHuman: _humanDuration(transcript.durationMs),
      sttProviderName: sttProviderName,
      diarizationAvailable: diarizationAvailable,
      userContext: userContext,
    );

    final userContent =
        '<transcript>\n${transcript.toPromptFormat()}\n</transcript>';

    final turns = <StructureTurn>[];
    var attempts = 0;
    int? inputTokens;
    int? outputTokens;

    while (true) {
      final response = await provider.structure(StructureRequest(
        systemPrompt: systemPrompt,
        userContent: userContent,
        schema: schema,
        priorTurns: turns,
      ));

      inputTokens = _add(inputTokens, response.inputTokens);
      outputTokens = _add(outputTokens, response.outputTokens);

      final parsed = extractJsonObject(response.rawText);
      final violations = parsed == null
          ? [
              const SchemaViolation(
                  '', 'response did not contain a JSON object'),
            ]
          : _validator.validate(parsed);

      if (violations.isEmpty && parsed != null) {
        return _finish(
          parsed,
          transcript,
          attempts,
          inputTokens,
          outputTokens,
        );
      }

      if (attempts >= maxRepairAttempts) {
        throw StructuringException(
          'The model could not produce a valid note after ${attempts + 1} attempts.',
          violations: violations.map((v) => v.toString()).toList(),
          lastResponse: response.rawText,
        );
      }

      // The repair turn carries only the errors — the transcript is already in the
      // conversation and re-sending it would cost the whole prompt again.
      turns
        ..add(StructureTurn('user', userContent))
        ..add(StructureTurn('assistant', response.rawText))
        ..add(StructureTurn(
          'user',
          StructuringPrompts.repair(
              violations.map((v) => v.toString()).toList()),
        ));
      attempts++;
    }
  }

  StructureOutcome _finish(
    Map<String, dynamic> parsed,
    Transcript transcript,
    int attempts,
    int? inputTokens,
    int? outputTokens,
  ) {
    final document = NoteDocument.fromJson(parsed);
    return StructureOutcome(
      document: document,
      raw: parsed,
      repairAttempts: attempts,
      unverifiedQuotes: verifyQuotes(document, transcript),
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  }

  /// Checks every cited quote against the transcript and returns the ids that failed.
  ///
  /// Deterministic, offline and free — the one hallucination check that costs nothing per
  /// run. Failures are surfaced in the UI as unverified rather than dropped: the item may
  /// still be real, and silently deleting a task is its own failure mode.
  static List<String> verifyQuotes(NoteDocument doc, Transcript transcript) {
    final verifier = QuoteVerifier(transcript.plainText);
    final flagged = <String>[];

    void check(String id, String quote) {
      if (verifier.verify(quote).shouldFlag) flagged.add(id);
    }

    for (final t in doc.tasks) {
      check(t.id, t.sourceRef.quote);
    }
    for (final d in doc.decisions) {
      check(d.id, d.sourceRef.quote);
    }
    for (final q in doc.openQuestions) {
      check(q.id, q.sourceRef.quote);
    }
    for (final r in doc.risks) {
      check(r.id, r.sourceRef.quote);
    }
    for (final a in doc.timelineAnchors) {
      check(a.label, a.sourceRef.quote);
    }
    return flagged;
  }

  /// Whether this transcript fits the provider's context in one pass.
  ///
  /// Under-estimating here means a silently truncated transcript, so the reserve is
  /// deliberately generous. A context window of zero means unknown — a local server that
  /// would not tell us — and unknown always takes the map/reduce path.
  bool fitsSinglePass(Transcript transcript) {
    final window = provider.capabilities.contextWindowTokens;
    if (window == 0) return false;
    const promptOverhead = 1200;
    final schemaTokens = (jsonEncode(schema).length / 3.5).ceil();
    final reserve = provider.capabilities.maxOutputTokens.clamp(2000, 16000);
    return transcript.estimatedTokens +
            promptOverhead +
            schemaTokens +
            reserve <
        window;
  }

  static int? _add(int? a, int? b) =>
      a == null && b == null ? null : (a ?? 0) + (b ?? 0);

  static String _humanDuration(int ms) {
    final minutes = (ms / 60000).round();
    if (minutes < 1) return 'under a minute';
    if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0
        ? '$hours hour${hours == 1 ? '' : 's'}'
        : '$hours h $rest min';
  }
}

/// Structuring failed in a way the user needs to know about. The raw transcript is
/// already saved by this point, so nothing is lost — the note can be retried, or retried
/// against a different provider.
class StructuringException implements Exception {
  const StructuringException(
    this.message, {
    this.violations = const [],
    this.lastResponse,
  });

  final String message;
  final List<String> violations;
  final String? lastResponse;

  @override
  String toString() => violations.isEmpty
      ? 'StructuringException: $message'
      : 'StructuringException: $message\n${violations.join('\n')}';
}
