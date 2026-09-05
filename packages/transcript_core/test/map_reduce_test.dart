import 'dart:convert';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

/// Records every prompt it is sent and replies with a queued response.
class ScriptedProvider extends StructuringProvider {
  ScriptedProvider(this.responses, {this.contextWindowTokens = 200000});

  final List<String> responses;
  final int contextWindowTokens;
  final List<StructureRequest> requests = [];

  @override
  ProviderId get id => const ProviderId('scripted');
  @override
  String get displayName => 'Scripted';
  @override
  ProviderCapabilities get capabilities => ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        contextWindowTokens: contextWindowTokens,
        maxOutputTokens: 4096,
      );
  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'ok');

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    requests.add(request);
    final index = requests.length - 1;
    return StructureResponse(
      rawText:
          responses[index < responses.length ? index : responses.length - 1],
      inputTokens: 100,
      outputTokens: 40,
    );
  }
}

void main() {
  Transcript longTranscript({int segments = 200}) => Transcript([
        for (var i = 0; i < segments; i++)
          TranscriptSegment(
            startMs: i * 5000,
            endMs: (i + 1) * 5000,
            text:
                'This is turn number $i and it carries a reasonable amount of '
                'speech so the window budget is actually consumed.',
            speaker: 'SPEAKER_0${i % 3}',
          ),
      ]);

  group('section planner', () {
    test('a transcript inside the budget is one window', () {
      final windows = const SectionPlanner()
          .split(longTranscript(segments: 3), budgetTokens: 100000);
      expect(windows, hasLength(1));
      expect(windows.single.total, 1);
    });

    test('splits a long transcript into windows within budget', () {
      final windows =
          const SectionPlanner().split(longTranscript(), budgetTokens: 2000);

      expect(windows.length, greaterThan(1));
      for (final window in windows) {
        expect(window.estimatedTokens, lessThanOrEqualTo(2600),
            reason:
                'a window that overflows the context is silently truncated');
      }
    });

    test('windows tile the transcript with nothing dropped or repeated', () {
      final transcript = longTranscript();
      final windows =
          const SectionPlanner().split(transcript, budgetTokens: 2000);

      final rebuilt = [for (final w in windows) ...w.segments];
      expect(rebuilt.length, transcript.segments.length,
          reason: 'losing a segment here loses that part of the meeting');
      expect(
        rebuilt.map((s) => s.startMs),
        orderedEquals(transcript.segments.map((s) => s.startMs)),
      );
    });

    test('windows are numbered for the prompt', () {
      final windows =
          const SectionPlanner().split(longTranscript(), budgetTokens: 2000);
      expect(windows.first.index, 1);
      expect(windows.last.index, windows.length);
      expect(windows.every((w) => w.total == windows.length), isTrue);
    });

    test('breaks on a speaker change rather than mid-turn', () {
      // Alternating speakers: every boundary should land where the speaker changes.
      final windows =
          const SectionPlanner().split(longTranscript(), budgetTokens: 1500);

      for (var i = 1; i < windows.length; i++) {
        final previous = windows[i - 1].segments.last.speaker;
        final next = windows[i].segments.first.speaker;
        expect(next, isNot(previous),
            reason:
                'cutting mid-turn produces half-formed items on both sides');
      }
    });

    test('a single segment larger than the budget gets its own window', () {
      final transcript = Transcript([
        TranscriptSegment(startMs: 0, endMs: 60000, text: 'word ' * 5000),
        const TranscriptSegment(
            startMs: 60000, endMs: 61000, text: 'short one'),
      ]);
      final windows =
          const SectionPlanner().split(transcript, budgetTokens: 500);

      expect(windows, hasLength(2));
      expect(windows.first.segments, hasLength(1),
          reason: 'it cannot be split without cutting mid-sentence');
    });

    test('an empty transcript plans nothing', () {
      expect(
          const SectionPlanner().split(const Transcript([]), budgetTokens: 100),
          isEmpty);
    });

    test(
        'a non-positive budget is a programming error, not a silent single window',
        () {
      expect(
        () => const SectionPlanner().split(longTranscript(), budgetTokens: 0),
        throwsArgumentError,
      );
    });
  });

  group('map/reduce', () {
    Future<StructureOutcome> runLong(
      ScriptedProvider provider, {
      void Function(StructureProgress)? onProgress,
    }) =>
        StructuringPipeline(provider: provider).run(
          transcript: longTranscript(),
          referenceDate: '2026-09-05',
          timeZone: 'UTC',
          sttProviderName: 'Whisper',
          onProgress: onProgress,
        );

    test('a transcript that fits takes one call', () async {
      final provider = ScriptedProvider([jsonEncode(validNoteJson())]);
      await StructuringPipeline(provider: provider).run(
        transcript: const Transcript([
          TranscriptSegment(startMs: 0, endMs: 5000, text: fixtureTranscript),
        ]),
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
        sttProviderName: 'Whisper',
      );
      expect(provider.requests, hasLength(1));
    });

    test('a transcript that does not fit is mapped then reduced', () async {
      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(validNoteJson())),
        contextWindowTokens: 8192,
      );
      await runLong(provider);

      expect(provider.requests.length, greaterThan(2),
          reason: 'several windows plus one merge');

      final prompts = provider.requests.map((r) => r.systemPrompt).toList();
      expect(prompts.where((p) => p.contains('SECTION')).length,
          provider.requests.length - 1);
      expect(prompts.last, contains('merging'),
          reason: 'the final call is the reduce pass');
    });

    test('each window is told to keep offsets absolute', () async {
      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(validNoteJson())),
        contextWindowTokens: 8192,
      );
      await runLong(provider);

      final mapPrompt = provider.requests
          .firstWhere((r) => r.systemPrompt.contains('SECTION'));
      expect(mapPrompt.systemPrompt, contains('absolute positions'));
    });

    test('the participant roster is carried forward between windows', () async {
      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(validNoteJson())),
        contextWindowTokens: 8192,
      );
      await runLong(provider);

      final sections = provider.requests
          .where((r) => r.systemPrompt.contains('SECTION'))
          .toList();
      expect(sections.first.systemPrompt, contains('[]'),
          reason: 'nobody is known before the first window');
      expect(sections[1].systemPrompt, contains('p_priya'),
          reason: 'four separate Sarahs in one note is what this prevents');
    });

    test('the reduce pass receives the partial documents, not the transcript',
        () async {
      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(validNoteJson())),
        contextWindowTokens: 8192,
      );
      await runLong(provider);

      final reduce = provider.requests.last;
      expect(reduce.userContent, contains('partial_documents'));
      expect(reduce.userContent, isNot(contains('This is turn number')),
          reason: 're-sending the transcript to merge would pay for it twice');
    });

    test('progress covers every window plus the merge', () async {
      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(validNoteJson())),
        contextWindowTokens: 8192,
      );
      final seen = <StructureProgress>[];
      await runLong(provider, onProgress: seen.add);

      expect(seen, isNotEmpty);
      expect(seen.last.fraction, 1.0);
      expect(seen.any((p) => p.isMerging), isTrue,
          reason: 'the merge is a visible step, not a mysterious pause at 90%');
    });

    test('tokens are summed across every window and the merge', () async {
      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(validNoteJson())),
        contextWindowTokens: 8192,
      );
      final outcome = await runLong(provider);

      expect(outcome.inputTokens, provider.requests.length * 100,
          reason: 'the cost meter must show what the whole note cost');
    });

    test('an unknown local context window takes the split path, conservatively',
        () async {
      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(validNoteJson())),
        contextWindowTokens: 0,
      );
      await runLong(provider);

      expect(provider.requests.length, greaterThan(1),
          reason:
              'unknown must never be optimistic — silent truncation is worse');
    });

    test('quotes are verified against the whole transcript, not one window',
        () async {
      final note = validNoteJson();
      (note['tasks'] as List<dynamic>).add({
        ...((note['tasks'] as List<dynamic>).first as Map<String, dynamic>),
        'id': 't_invented',
        'sourceRef': {
          'startMs': 1,
          'endMs': 2,
          'quote': 'nobody said any of these words at all',
        },
      });

      final provider = ScriptedProvider(
        List.filled(20, jsonEncode(note)),
        contextWindowTokens: 8192,
      );
      final outcome = await runLong(provider);

      expect(outcome.unverifiedQuotes, contains('t_invented'));
    });
  });
}
