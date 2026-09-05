import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

/// Returns fixed bytes and records which chunks were asked for.
class _FakeAudio implements ChunkAudioReader {
  _FakeAudio({this.failOnIndex});

  final int? failOnIndex;
  final List<PlannedChunk> reads = [];

  @override
  String get mimeType => 'audio/wav';

  @override
  Future<List<int>> read(PlannedChunk chunk) async {
    reads.add(chunk);
    if (chunk.index == failOnIndex) throw StateError('audio file truncated');
    return List.filled(16, 0);
  }
}

/// One segment per chunk, so assembly and ordering are observable.
class _PerChunkTranscription extends TranscriptionProvider {
  _PerChunkTranscription({this.failOnOffsetMs});

  final int? failOnOffsetMs;
  final List<TranscribeRequest> requests = [];

  @override
  ProviderId get id => const ProviderId('per-chunk');
  @override
  String get displayName => 'Per-chunk fake';
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
    requests.add(request);
    if (request.offsetMs == failOnOffsetMs) {
      throw const ProviderException('Whisper', 500, 'upstream error');
    }
    return [
      TranscriptSegment(
        startMs: request.offsetMs,
        endMs: request.offsetMs + 1000,
        text: 'chunk at ${request.offsetMs}',
      ),
    ];
  }
}

void main() {
  StructuringPipeline structuringWith(String response) => StructuringPipeline(
      provider: FakeStructuringProvider(response: response));

  RecordingPipeline pipelineWith(
    TranscriptionProvider transcription, {
    StructuringPipeline? structuring,
  }) =>
      RecordingPipeline(
        transcription: transcription,
        structuring:
            structuring ?? structuringWith(jsonEncode(validNoteJson())),
      );

  Future<List<PipelineEvent>> collect(Stream<PipelineEvent> stream) =>
      stream.toList();

  test('a short recording is one chunk and produces a note', () async {
    final transcription = _PerChunkTranscription();
    final audio = _FakeAudio();

    final events = await collect(pipelineWith(transcription).run(
      totalDurationMs: 30000,
      silences: const [],
      audio: audio,
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
    ));

    expect(audio.reads, hasLength(1));
    expect(events.last, isA<PipelineComplete>());
    expect(
        (events.last as PipelineComplete).outcome.document.tasks, hasLength(1));
  });

  test(
      'progress is reported per batch so the UI is not an indeterminate spinner',
      () async {
    final events = await collect(pipelineWith(_PerChunkTranscription()).run(
      totalDurationMs: 300000,
      silences: [
        for (var t = 40; t < 300; t += 40)
          SilenceWindow(t * 1000, t * 1000 + 600),
      ],
      audio: _FakeAudio(),
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
    ));

    final progress = events.whereType<TranscribingChunk>().toList();
    expect(progress.first.completed, 0);
    expect(progress.last.completed, progress.last.total);
    expect(progress.last.fraction, 1.0);
    expect(progress.length, greaterThan(2),
        reason: 'progress advances during the run');
  });

  test('chunks are transcribed with absolute offsets, in plan order', () async {
    final transcription = _PerChunkTranscription();

    await collect(pipelineWith(transcription).run(
      totalDurationMs: 200000,
      silences: [
        for (var t = 44; t < 200; t += 44)
          SilenceWindow(t * 1000, t * 1000 + 600),
      ],
      audio: _FakeAudio(),
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
    ));

    final offsets = transcription.requests.map((r) => r.offsetMs).toList();
    expect(offsets.first, 0);
    expect(offsets, orderedEquals([...offsets]..sort()));
  });

  test('the priming prompt carries the previous chunk forward', () async {
    final transcription = _PerChunkTranscription();

    await collect(
      RecordingPipeline(
        transcription: transcription,
        structuring: structuringWith(jsonEncode(validNoteJson())),
        maxConcurrent: 1, // so chunk n-1 has finished before chunk n starts
      ).run(
        totalDurationMs: 200000,
        silences: [
          for (var t = 44; t < 200; t += 44)
            SilenceWindow(t * 1000, t * 1000 + 600),
        ],
        audio: _FakeAudio(),
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
      ),
    );

    expect(transcription.requests.first.primingPrompt, isNull,
        reason: 'the first chunk has nothing to prime from');
    expect(transcription.requests[1].primingPrompt, contains('chunk at 0'));
  });

  group('failure isolation', () {
    test('a failed chunk is reported but the recording still produces a note',
        () async {
      final events = await collect(
        pipelineWith(_PerChunkTranscription(failOnOffsetMs: 41300)).run(
          totalDurationMs: 200000,
          silences: [
            for (var t = 44; t < 200; t += 44)
              SilenceWindow(t * 1000, t * 1000 + 600),
          ],
          audio: _FakeAudio(),
          referenceDate: '2026-09-05',
          timeZone: 'UTC',
        ),
      );

      final failures = events.whereType<ChunkFailed>().toList();
      expect(failures, hasLength(1));
      expect(failures.single.reason, contains('upstream error'));

      final complete = events.last as PipelineComplete;
      expect(complete.transcript.gaps, hasLength(1));
      expect(complete.transcript.segments, isNotEmpty,
          reason: 'the surviving chunks still made a transcript');
    });

    test('unreadable audio for one chunk is also isolated', () async {
      final events = await collect(
        pipelineWith(_PerChunkTranscription()).run(
          totalDurationMs: 200000,
          silences: [
            for (var t = 44; t < 200; t += 44)
              SilenceWindow(t * 1000, t * 1000 + 600),
          ],
          audio: _FakeAudio(failOnIndex: 1),
          referenceDate: '2026-09-05',
          timeZone: 'UTC',
        ),
      );

      expect(events.whereType<ChunkFailed>().single.index, 1);
      expect(events.last, isA<PipelineComplete>());
    });

    test('a structuring failure keeps the transcript', () async {
      final events = await collect(
        pipelineWith(
          _PerChunkTranscription(),
          structuring: structuringWith('not json at all'),
        ).run(
          totalDurationMs: 30000,
          silences: const [],
          audio: _FakeAudio(),
          referenceDate: '2026-09-05',
          timeZone: 'UTC',
        ),
      );

      final failed = events.last as PipelineFailed;
      expect(failed.transcript.segments, isNotEmpty,
          reason:
              'the user must not lose the recording because the model misbehaved');
      expect(failed.error, isA<StructuringException>());
    });
  });

  test('the chunker respects the provider byte ceiling', () async {
    final audio = _FakeAudio();
    // A provider capping requests at 1 MiB: 1 MiB * 0.8 headroom / 32 kB/s ≈ 26 s.
    await collect(pipelineWith(_SmallRequestTranscription()).run(
      totalDurationMs: 120000,
      silences: const [],
      audio: audio,
      referenceDate: '2026-09-05',
      timeZone: 'UTC',
    ));

    expect(audio.reads.length, greaterThan(3),
        reason:
            'a 1 MiB cap forces many more chunks than the 45s target would');
    // What matters is the bytes actually uploaded, which include the overlap the chunk
    // carries — not just its new content.
    for (final chunk in audio.reads) {
      final bytes = chunk.durationMs * 32000 ~/ 1000;
      expect(bytes, lessThanOrEqualTo(1024 * 1024),
          reason:
              'chunk ${chunk.index} would exceed the provider request limit');
    }
  });

  group('live transcription', () {
    test('collects segments while recording and hands them over on stop',
        () async {
      final source = _FakeLiveSource();
      final adapter = LiveTranscriptionAdapter(source);

      await adapter.startListening();
      source.emit(0, 2000, 'Morning everyone.');
      source.emit(2000, 5000, 'Lets talk about auth.');
      final transcript = await adapter.stopListening();

      expect(transcript.segments, hasLength(2));
      expect(transcript.plainText, contains('Lets talk about auth'));
    });

    test('segments are ordered even if recognition finalises out of order',
        () async {
      final source = _FakeLiveSource();
      final adapter = LiveTranscriptionAdapter(source);

      await adapter.startListening();
      source.emit(5000, 7000, 'second');
      source.emit(0, 2000, 'first');
      final transcript = await adapter.stopListening();

      expect(transcript.segments.map((s) => s.text), ['first', 'second']);
    });

    test('presents itself as a normal transcription provider to the pipeline',
        () async {
      final source = _FakeLiveSource();
      final adapter = LiveTranscriptionAdapter(source);
      await adapter.startListening();
      source.emit(0, 3000, 'already transcribed live');
      await adapter.stopListening();

      final events = await collect(pipelineWith(adapter).run(
        totalDurationMs: 3000,
        silences: const [],
        audio: _FakeAudio(),
        referenceDate: '2026-09-05',
        timeZone: 'UTC',
      ));

      expect(events.last, isA<PipelineComplete>(),
          reason:
              'the notes path is identical whichever source the user chose');
    });
  });
}

class _SmallRequestTranscription extends _PerChunkTranscription {
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        maxRequestBytes: 1024 * 1024,
      );
}

class _FakeLiveSource extends LiveTranscriptionSource {
  final _controller = StreamController<TranscriptSegment>.broadcast();
  bool started = false;

  @override
  Stream<TranscriptSegment> get segments => _controller.stream;

  @override
  ProviderId get id => const ProviderId('fake-live');
  @override
  String get displayName => 'On-device (fake)';
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        requiresApiKey: false,
        runsOnDevice: true,
      );
  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'Ready · on-device');

  @override
  Future<void> start({String? languageHint}) async => started = true;

  @override
  Future<void> stop() async {
    started = false;
    await _controller.close();
  }

  void emit(int start, int end, String text) => _controller
      .add(TranscriptSegment(startMs: start, endMs: end, text: text));
}
