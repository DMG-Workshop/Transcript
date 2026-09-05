import 'dart:convert';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

class MemoryStore implements ChunkStore {
  final Map<String, ChunkRecord> rows = {};

  @override
  Future<List<ChunkRecord>> forRecording(String id) async =>
      rows.values.where((c) => c.recordingId == id).toList()
        ..sort((a, b) => a.index.compareTo(b.index));

  @override
  Future<void> putAll(List<ChunkRecord> chunks) async {
    for (final c in chunks) {
      rows[c.id] = c;
    }
  }

  @override
  Future<void> update(ChunkRecord chunk) async => rows[chunk.id] = chunk;
}

class StubAudio implements ChunkAudioReader {
  @override
  String get mimeType => 'audio/wav';
  @override
  Future<List<int>> read(PlannedChunk chunk) async => List.filled(8, 0);
}

class Speech extends TranscriptionProvider {
  Speech({this.failOffsetsAfter});

  /// Fails every chunk whose offset is at or past this, so a test does not have to
  /// predict where the planner will cut.
  final int? failOffsetsAfter;
  int calls = 0;

  @override
  ProviderId get id => const ProviderId('speech');
  @override
  String get displayName => 'Speech';
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        maxRequestBytes: 25 * 1024 * 1024,
      );
  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'ok');

  @override
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request) async {
    calls++;
    if (failOffsetsAfter != null && request.offsetMs >= failOffsetsAfter!) {
      throw const ProviderException('Speech', 400, 'malformed audio');
    }
    return [
      TranscriptSegment(
        startMs: request.offsetMs,
        endMs: request.offsetMs + 45000,
        text:
            'distinct speech beginning at offset ${request.offsetMs} of the meeting',
      ),
    ];
  }
}

void main() {
  DurableRecordingPipeline pipelineOf(
    MemoryStore store,
    TranscriptionProvider speech, {
    String? structuringResponse,
  }) =>
      DurableRecordingPipeline(
        queue: ChunkQueue(
          store: store,
          transcription: speech,
          audio: StubAudio(),
          policy: const RetryPolicy(base: Duration(milliseconds: 1)),
        ),
        structuring: StructuringPipeline(
          provider: FakeStructuringProvider(
            response: structuringResponse ?? jsonEncode(validNoteJson()),
          ),
        ),
      );

  Future<List<PipelineEvent>> collect(Stream<PipelineEvent> s) => s.toList();

  test('plans, transcribes and structures a recording end to end', () async {
    final store = MemoryStore();
    final events = await collect(pipelineOf(store, Speech()).start(
      recordingId: 'r1',
      totalDurationMs: 150000,
      silences: const [
        SilenceWindow(44000, 44800),
        SilenceWindow(92000, 92900),
      ],
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
    ));

    expect(events.last, isA<PipelineComplete>());
    expect(store.rows, isNotEmpty);
    expect(
      store.rows.values.every((c) => c.state == ChunkState.transcribed),
      isTrue,
    );
  });

  test('progress reaches the total before structuring begins', () async {
    final events = await collect(pipelineOf(MemoryStore(), Speech()).start(
      recordingId: 'r1',
      totalDurationMs: 150000,
      silences: const [
        SilenceWindow(44000, 44800),
        SilenceWindow(92000, 92900)
      ],
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
    ));

    final progress = events.whereType<TranscribingChunk>().toList();
    expect(progress.first.completed, 0);
    expect(progress.last.completed, progress.last.total);

    final structuringAt = events.indexWhere((e) => e is Structuring);
    final lastProgressAt = events.lastIndexWhere((e) => e is TranscribingChunk);
    expect(lastProgressAt, lessThan(structuringAt));
  });

  group('resuming', () {
    test('a killed process picks up where it stopped', () async {
      final store = MemoryStore();
      final firstRun = Speech();

      // First attempt: plan and transcribe one of three chunks, then "die".
      final pipeline = pipelineOf(store, firstRun);
      await pipeline.queue.enqueue('r1', [
        for (var i = 0; i < 3; i++)
          PlannedChunk(
            index: i,
            startMs: i == 0 ? 0 : i * 45000 - 3000,
            contentStartMs: i * 45000,
            endMs: (i + 1) * 45000,
            boundary: ChunkBoundary.silence,
          ),
      ]);
      final first = (await store.forRecording('r1')).first;
      await store.update(first.copyWith(
        state: ChunkState.transcribed,
        segments: const [
          TranscriptSegment(
              startMs: 0,
              endMs: 45000,
              text: 'the first chunk was already done'),
        ],
      ));

      // Relaunch.
      final secondRun = Speech();
      final resumed = pipelineOf(store, secondRun);
      final events = await collect(resumed.resume(
        recordingId: 'r1',
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
      ));

      expect(secondRun.calls, 2,
          reason: 'only the two unfinished chunks are re-sent');
      expect(events.last, isA<PipelineComplete>());
      final transcript = (events.last as PipelineComplete).transcript;
      expect(transcript.segments, hasLength(3));
    });

    test(
        'resuming an already-finished recording structures without re-uploading',
        () async {
      final store = MemoryStore();
      final speech = Speech();
      final pipeline = pipelineOf(store, speech);

      await pipeline.queue.enqueue('r1', [
        const PlannedChunk(
          index: 0,
          startMs: 0,
          contentStartMs: 0,
          endMs: 45000,
          boundary: ChunkBoundary.end,
        ),
      ]);
      final only = (await store.forRecording('r1')).single;
      await store.update(only.copyWith(
        state: ChunkState.transcribed,
        segments: const [
          TranscriptSegment(
              startMs: 0, endMs: 45000, text: 'everything was captured'),
        ],
      ));

      final events = await collect(pipeline.resume(
        recordingId: 'r1',
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
      ));

      expect(speech.calls, 0, reason: 'work already paid for is never redone');
      expect(events.last, isA<PipelineComplete>());
    });
  });

  test('a permanently failed chunk is reported and becomes a gap', () async {
    final store = MemoryStore();
    final events = await collect(
      pipelineOf(store, Speech(failOffsetsAfter: 80000)).start(
        recordingId: 'r1',
        totalDurationMs: 150000,
        silences: const [
          SilenceWindow(44000, 44800),
          SilenceWindow(92000, 92900)
        ],
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
      ),
    );

    expect(events.whereType<ChunkFailed>(), hasLength(1));
    final complete = events.last as PipelineComplete;
    expect(complete.transcript.gaps, hasLength(1));
    expect(complete.transcript.segments, isNotEmpty);
  });

  test('a structuring failure still surfaces the transcript', () async {
    final events = await collect(
      pipelineOf(MemoryStore(), Speech(), structuringResponse: 'not json')
          .start(
        recordingId: 'r1',
        totalDurationMs: 40000,
        silences: const [],
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
      ),
    );

    final failed = events.last as PipelineFailed;
    expect(failed.transcript.segments, isNotEmpty);
    expect(failed.error, isA<StructuringException>());
  });

  test('an interruption becomes a visible gap in the transcript', () async {
    // A phone call takes the microphone without any chunk failing, so the queue knows
    // nothing about it. The recorder does, and passes it in.
    final events = await collect(pipelineOf(MemoryStore(), Speech()).start(
      recordingId: 'r1',
      totalDurationMs: 40000,
      silences: const [],
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
      additionalGaps: const [
        TranscriptGap(12000, 30000, 'interrupted by another app'),
      ],
    ));

    final complete = events.last as PipelineComplete;
    expect(complete.transcript.gaps, hasLength(1));
    expect(complete.transcript.toPromptFormat(), contains('unintelligible'),
        reason: 'the model must see a hole, not a meeting that skips a beat');
  });

  test('the chunk plan respects the provider byte ceiling', () async {
    final store = MemoryStore();
    await collect(pipelineOf(store, _SmallRequest()).start(
      recordingId: 'r1',
      totalDurationMs: 300000,
      silences: const [],
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
    ));

    for (final chunk in store.rows.values) {
      final bytes = (chunk.endMs - chunk.startMs) * 32000 ~/ 1000;
      expect(bytes, lessThanOrEqualTo(1024 * 1024));
    }
  });
}

class _SmallRequest extends Speech {
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        maxRequestBytes: 1024 * 1024,
      );
}
