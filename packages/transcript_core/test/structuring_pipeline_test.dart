import 'dart:convert';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  Transcript transcriptFixture() => const Transcript([
        TranscriptSegment(
            startMs: 12000, endMs: 90000, text: fixtureTranscript),
      ]);

  Future<StructureOutcome> run(FakeStructuringProvider provider) =>
      StructuringPipeline(provider: provider).run(
        transcript: transcriptFixture(),
        referenceDate: '2026-09-05',
        timeZone: 'America/New_York',
        sttProviderName: 'On-device',
      );

  test('a valid response produces a note with no repairs', () async {
    final provider =
        FakeStructuringProvider(response: jsonEncode(validNoteJson()));
    final outcome = await run(provider);

    expect(outcome.repairAttempts, 0);
    expect(outcome.document.tasks.single.title,
        contains('Migrate the auth service'));
    expect(outcome.document.tasks.single.dateBasis, DateBasis.explicit);
    expect(outcome.unverifiedQuotes, isEmpty);
  });

  test('a fenced response is recovered without a round-trip', () async {
    final provider = FakeStructuringProvider(
      response: '```json\n${jsonEncode(validNoteJson())}\n```',
    );
    final outcome = await run(provider);
    expect(outcome.repairAttempts, 0);
  });

  test('the system prompt carries the recording date so relative dates resolve',
      () async {
    final provider =
        FakeStructuringProvider(response: jsonEncode(validNoteJson()));
    await run(provider);

    final prompt = provider.requests.single.systemPrompt;
    expect(prompt, contains('2026-09-05'));
    expect(prompt, contains('America/New_York'));
    expect(prompt, contains('dateBasis'));
  });

  test('the transcript is sent with timestamps the model can cite', () async {
    final provider =
        FakeStructuringProvider(response: jsonEncode(validNoteJson()));
    await run(provider);
    expect(provider.requests.single.userContent, startsWith('<transcript>'));
  });

  group('repair loop', () {
    test('an invalid response is repaired without re-sending the transcript',
        () async {
      final broken = validNoteJson();
      ((broken['tasks'] as List<dynamic>).first
          as Map<String, dynamic>)['dateBasis'] = 'probably';

      final provider = _ScriptedProvider([
        jsonEncode(broken),
        jsonEncode(validNoteJson()),
      ]);

      final outcome = await StructuringPipeline(provider: provider).run(
        transcript: transcriptFixture(),
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
        sttProviderName: 'Whisper',
      );

      expect(outcome.repairAttempts, 1);
      expect(outcome.document.tasks, hasLength(1));

      final repairTurns = provider.requests.last.priorTurns;
      expect(repairTurns.last.content, contains('/tasks/0/dateBasis'),
          reason: 'the repair turn names the exact violation');
      expect(repairTurns.last.content, isNot(contains('legacy session store')),
          reason:
              'the transcript is already in the conversation; re-sending it '
              'would pay for the whole prompt again');
    });

    test('gives up after the configured attempts rather than looping',
        () async {
      final broken = validNoteJson()..remove('tasks');
      final provider = _ScriptedProvider(List.filled(6, jsonEncode(broken)));

      await expectLater(
        StructuringPipeline(provider: provider, maxRepairAttempts: 2).run(
          transcript: transcriptFixture(),
          referenceDate: '2026-09-05',
          timeZone: 'UTC',
          sttProviderName: 'Whisper',
        ),
        throwsA(isA<StructuringException>()
            .having((e) => e.violations, 'violations', isNotEmpty)),
      );

      expect(provider.requests, hasLength(3),
          reason: 'initial call plus two repairs');
    });

    test('a response with no JSON at all enters the repair loop', () async {
      final provider = _ScriptedProvider([
        'I am unable to structure this transcript.',
        jsonEncode(validNoteJson()),
      ]);

      final outcome = await StructuringPipeline(provider: provider).run(
        transcript: transcriptFixture(),
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
        sttProviderName: 'Whisper',
      );
      expect(outcome.repairAttempts, 1);
    });
  });

  group('quote verification', () {
    test('a task citing words never spoken is flagged, not dropped', () async {
      final fabricated = validNoteJson();
      (fabricated['tasks'] as List<dynamic>).add({
        ...((fabricated['tasks'] as List<dynamic>).first
            as Map<String, dynamic>),
        'id': 't_invented',
        'title': 'Set up the billing integration',
        'sourceRef': {
          'startMs': 70000,
          'endMs': 80000,
          'quote': 'Dennis will own the billing integration this sprint',
        },
      });

      final outcome = await run(
        FakeStructuringProvider(response: jsonEncode(fabricated)),
      );

      expect(outcome.unverifiedQuotes, ['t_invented']);
      expect(outcome.document.tasks, hasLength(2),
          reason: 'flagged, not silently deleted — it may still be real');
    });

    test('quotes across every item type are checked', () async {
      final doc = validNoteJson();
      (doc['risks'] as List<dynamic>).add({
        'id': 'r_fake',
        'description': 'Invented risk',
        'severity': 'high',
        'sourceRef': {
          'startMs': 1,
          'endMs': 2,
          'quote': 'the vendor contract expires in November',
        },
      });

      final outcome =
          await run(FakeStructuringProvider(response: jsonEncode(doc)));
      expect(outcome.unverifiedQuotes, contains('r_fake'));
    });
  });

  test('an empty transcript fails before spending a request', () async {
    final provider = FakeStructuringProvider(response: '{}');
    await expectLater(
      StructuringPipeline(provider: provider).run(
        transcript: const Transcript([]),
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
        sttProviderName: 'On-device',
      ),
      throwsA(isA<StructuringException>()),
    );
    expect(provider.requests, isEmpty);
  });

  group('single-pass budget', () {
    test('a short transcript fits a large context', () {
      final pipeline = StructuringPipeline(
        provider: FakeStructuringProvider(response: '{}'),
      );
      expect(pipeline.fitsSinglePass(transcriptFixture()), isTrue);
    });

    test('an unknown context window always takes the map/reduce path', () {
      final pipeline = StructuringPipeline(
        provider: _ZeroContextProvider(),
      );
      expect(pipeline.fitsSinglePass(transcriptFixture()), isFalse,
          reason: 'unknown must never be optimistic — silent truncation is the '
              'worst outcome');
    });

    test('an hour of speech does not fit a small local context', () {
      final pipeline = StructuringPipeline(provider: _SmallContextProvider());
      final long = Transcript([
        TranscriptSegment(startMs: 0, endMs: 3600000, text: 'word ' * 10000),
      ]);
      expect(pipeline.fitsSinglePass(long), isFalse);
    });
  });

  test('token usage is summed across repair round-trips', () async {
    final broken = validNoteJson()..remove('risks');
    final provider =
        _ScriptedProvider([jsonEncode(broken), jsonEncode(validNoteJson())]);

    final outcome = await StructuringPipeline(provider: provider).run(
      transcript: transcriptFixture(),
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
      sttProviderName: 'Whisper',
    );

    // The cost meter must show what the note actually cost, repairs included.
    expect(outcome.inputTokens, 200);
    expect(outcome.outputTokens, 100);
  });
}

/// Returns a queued response per call, so the repair loop can be driven deterministically.
class _ScriptedProvider extends StructuringProvider {
  _ScriptedProvider(this._responses);

  final List<String> _responses;
  final List<StructureRequest> requests = [];

  @override
  ProviderId get id => const ProviderId('scripted');
  @override
  String get displayName => 'Scripted';
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        contextWindowTokens: 200000,
      );
  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'ok');

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    requests.add(request);
    return StructureResponse(
      rawText: _responses[requests.length - 1],
      inputTokens: 100,
      outputTokens: 50,
    );
  }
}

class _ZeroContextProvider extends _ScriptedProvider {
  _ZeroContextProvider() : super(const []);

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
      );
}

class _SmallContextProvider extends _ScriptedProvider {
  _SmallContextProvider() : super(const []);

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        contextWindowTokens: 4096,
        maxOutputTokens: 2048,
      );
}
