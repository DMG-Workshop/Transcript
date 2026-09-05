import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

/// An in-memory [ChunkStore] that behaves like the database: values are written out and
/// read back, so nothing survives in an object the queue happens to be holding.
class FakeStore implements ChunkStore {
  final Map<String, ChunkRecord> rows = {};
  int writes = 0;

  @override
  Future<List<ChunkRecord>> forRecording(String recordingId) async =>
      rows.values.where((c) => c.recordingId == recordingId).toList()
        ..sort((a, b) => a.index.compareTo(b.index));

  @override
  Future<void> putAll(List<ChunkRecord> chunks) async {
    for (final chunk in chunks) {
      rows[chunk.id] = chunk;
      writes++;
    }
  }

  @override
  Future<void> update(ChunkRecord chunk) async {
    rows[chunk.id] = chunk;
    writes++;
  }
}

class FakeAudio implements ChunkAudioReader {
  @override
  String get mimeType => 'audio/wav';
  @override
  Future<List<int>> read(PlannedChunk chunk) async => List.filled(8, 0);
}

/// Fails the given chunk offsets a set number of times before succeeding.
class FlakyTranscription extends TranscriptionProvider {
  FlakyTranscription({
    this.failuresByOffset = const {},
    this.errorFor,
  });

  /// offsetMs -> how many times to fail before succeeding.
  final Map<int, int> failuresByOffset;
  final Object Function(int offsetMs)? errorFor;

  final Map<int, int> seen = {};
  final List<TranscribeRequest> requests = [];

  @override
  ProviderId get id => const ProviderId('flaky');
  @override
  String get displayName => 'Flaky';
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
    final count =
        seen.update(request.offsetMs, (v) => v + 1, ifAbsent: () => 1);
    final budget = failuresByOffset[request.offsetMs] ?? 0;
    if (count <= budget) {
      throw errorFor?.call(request.offsetMs) ??
          const ProviderException('Flaky', 503, 'service unavailable');
    }
    // Spans the whole chunk, as a real provider would. A one-second segment at the
    // start of a chunk sits entirely inside the overlap window and is correctly
    // discarded by the assembler as content the previous chunk already covered.
    return [
      TranscriptSegment(
        startMs: request.offsetMs,
        endMs: request.offsetMs + 45000,
        text: 'chunk at ${request.offsetMs}',
      ),
    ];
  }
}

/// Distinct speech for the chunks that finished before the crash. Near-identical text
/// across a seam is indistinguishable from a duplicated overlap, which is exactly what
/// the assembler removes.
const _priorSpeech = [
  'okay lets start with the auth migration',
  'the session store cannot handle launch traffic',
  'and we agreed priya owns it',
];

void main() {
  List<PlannedChunk> planOf(int count) => [
        for (var i = 0; i < count; i++)
          PlannedChunk(
            index: i,
            startMs: i == 0 ? 0 : i * 45000 - 3000,
            contentStartMs: i * 45000,
            endMs: (i + 1) * 45000,
            boundary: ChunkBoundary.silence,
          ),
      ];

  ChunkQueue queueWith(
    FakeStore store,
    TranscriptionProvider transcription, {
    RetryPolicy policy = const RetryPolicy(base: Duration(milliseconds: 1)),
    int maxConcurrent = 2,
  }) =>
      ChunkQueue(
        store: store,
        transcription: transcription,
        audio: FakeAudio(),
        policy: policy,
        maxConcurrent: maxConcurrent,
        random: math.Random(7),
      );

  group('enqueue', () {
    test('writes every planned chunk exactly once', () async {
      final store = FakeStore();
      final queue = queueWith(store, FlakyTranscription());

      await queue.enqueue('r1', planOf(4));
      expect(store.rows, hasLength(4));
      expect(store.rows.values.every((c) => c.state == ChunkState.pending),
          isTrue);
    });

    test('re-enqueueing after a crash does not reset finished work', () async {
      final store = FakeStore();
      final queue = queueWith(store, FlakyTranscription());

      await queue.enqueue('r1', planOf(3));
      await store.update(store.rows.values.first.copyWith(
        state: ChunkState.transcribed,
        segments: const [TranscriptSegment(startMs: 0, endMs: 1, text: 'done')],
      ));

      // The app relaunches and re-registers the same plan.
      await queue.enqueue('r1', planOf(3));

      final chunk0 =
          (await store.forRecording('r1')).firstWhere((c) => c.index == 0);
      expect(chunk0.state, ChunkState.transcribed,
          reason: 'work already paid for must not be redone');
      expect(chunk0.segments, isNotEmpty);
    });
  });

  group('draining', () {
    test('transcribes every chunk and assembles them in order', () async {
      final store = FakeStore();
      final transcription = FlakyTranscription();
      final transcript = await queueWith(store, transcription).drain('r1_seed');

      // Nothing enqueued yet: an empty recording drains immediately.
      expect(transcript.segments, isEmpty);

      final queue = queueWith(store, transcription);
      await queue.enqueue('r1', planOf(3));
      final result = await queue.drain('r1');

      expect(result.segments, hasLength(3));
      expect(result.segments.map((s) => s.startMs), [0, 42000, 87000]);
      expect(result.gaps, isEmpty);
    });

    test('respects the concurrency limit', () async {
      final store = FakeStore();
      var peak = 0;
      var current = 0;

      final transcription = _CountingTranscription(
          onStart: () {
            current++;
            peak = math.max(peak, current);
          },
          onEnd: () => current--);

      final queue = queueWith(store, transcription, maxConcurrent: 2);
      await queue.enqueue('r1', planOf(6));
      await queue.drain('r1');

      expect(peak, lessThanOrEqualTo(2),
          reason:
              'unbounded concurrency is how a long recording trips a rate limit');
    });

    test('the priming prompt is read back from the store, not from memory',
        () async {
      final store = FakeStore();
      final transcription = FlakyTranscription();

      final queue = queueWith(store, transcription, maxConcurrent: 1);
      await queue.enqueue('r1', planOf(3));
      await queue.drain('r1');

      final second =
          transcription.requests.firstWhere((r) => r.offsetMs == 42000);
      expect(second.primingPrompt, contains('chunk at 0'),
          reason:
              'priming has to survive a restart, so it comes from the store');
    });
  });

  group('retries', () {
    test('a transient failure is retried and then succeeds', () async {
      final store = FakeStore();
      final transcription = FlakyTranscription(failuresByOffset: {0: 2});

      final queue = queueWith(store, transcription);
      await queue.enqueue('r1', planOf(1));
      final transcript = await queue.drain('r1');

      expect(transcription.seen[0], 3, reason: 'two failures, then success');
      expect(transcript.gaps, isEmpty);
      expect(transcript.segments, hasLength(1));
    });

    test('gives up after maxAttempts and becomes a gap, not a failed recording',
        () async {
      final store = FakeStore();
      final transcription = FlakyTranscription(failuresByOffset: {42000: 99});

      final queue = queueWith(
        store,
        transcription,
        policy:
            const RetryPolicy(maxAttempts: 3, base: Duration(milliseconds: 1)),
      );
      await queue.enqueue('r1', planOf(3));
      final transcript = await queue.drain('r1');

      expect(transcription.seen[42000], 3);
      expect(transcript.gaps, hasLength(1));
      expect(transcript.segments, hasLength(2),
          reason: 'the other chunks still made a transcript');
    });

    test('a rejected key is not retried at all', () async {
      final store = FakeStore();
      final transcription = FlakyTranscription(
        failuresByOffset: {0: 99},
        errorFor: (_) =>
            const ProviderException('Flaky', 401, 'invalid api key'),
      );

      final queue = queueWith(store, transcription);
      await queue.enqueue('r1', planOf(1));
      await queue.drain('r1');

      expect(transcription.seen[0], 1,
          reason:
              'a bad key fails identically forever; retrying wastes the user\'s '
              'time and their credit');
    });

    test('an oversized chunk rejected before sending is not retried', () async {
      final store = FakeStore();
      final transcription = FlakyTranscription(
        failuresByOffset: {0: 99},
        errorFor: (_) => const ProviderException('Flaky', 0, 'chunk too large'),
      );

      final queue = queueWith(store, transcription);
      await queue.enqueue('r1', planOf(1));
      await queue.drain('r1');

      expect(transcription.seen[0], 1);
    });

    test('a network drop is retried', () async {
      final store = FakeStore();
      final transcription = FlakyTranscription(
        failuresByOffset: {0: 1},
        errorFor: (_) => const TransportException(
            TransportFailure.refused, 'connection refused'),
      );

      final queue = queueWith(store, transcription);
      await queue.enqueue('r1', planOf(1));
      final transcript = await queue.drain('r1');

      expect(transcription.seen[0], 2);
      expect(transcript.gaps, isEmpty);
    });
  });

  group('resuming', () {
    test('a chunk stranded in uploading by a killed process is reclaimed',
        () async {
      final store = FakeStore();
      final transcription = FlakyTranscription();

      final queue = queueWith(store, transcription);
      await queue.enqueue('r1', planOf(2));

      // The app died mid-upload: one row is left claimed by a process that is gone.
      final stranded = (await store.forRecording('r1'))
          .first
          .copyWith(state: ChunkState.uploading);
      await store.update(stranded);

      final transcript = await queue.drain('r1');
      expect(transcript.segments, hasLength(2),
          reason:
              'a stranded chunk must go back in the queue, not hang the drain');
    });

    test('a drain that resumes only re-uploads what did not finish', () async {
      final store = FakeStore();
      final first = FlakyTranscription();

      final queue = queueWith(store, first);
      await queue.enqueue('r1', planOf(3));

      // Simulate the first two finishing before the app was killed.
      for (final chunk in (await store.forRecording('r1')).take(2)) {
        await store.update(chunk.copyWith(
          state: ChunkState.transcribed,
          segments: [
            TranscriptSegment(
                startMs: chunk.startMs,
                endMs: chunk.endMs,
                text: _priorSpeech[chunk.index]),
          ],
        ));
      }

      final second = FlakyTranscription();
      final resumed = queueWith(store, second);
      final transcript = await resumed.drain('r1');

      expect(second.requests, hasLength(1),
          reason: 'only the unfinished chunk is re-uploaded');
      expect(second.requests.single.offsetMs, 87000);
      expect(transcript.segments, hasLength(3));
    });
  });

  group('backoff schedule', () {
    const policy = RetryPolicy(base: Duration(seconds: 2));

    test('grows exponentially', () {
      final random = math.Random(1);
      final first = policy.backoffFor(1, random: random);
      final third = policy.backoffFor(3, random: random);
      expect(first.inMilliseconds, greaterThanOrEqualTo(2000));
      expect(third.inMilliseconds, greaterThan(first.inMilliseconds * 2));
    });

    test('is capped so a long outage does not schedule an hour out', () {
      expect(policy.backoffFor(20, random: math.Random(1)).inMinutes,
          lessThanOrEqualTo(7));
    });

    test(
        'carries jitter so chunks that failed together do not retry in lockstep',
        () {
      final delays = {
        for (var i = 0; i < 12; i++)
          policy.backoffFor(3, random: math.Random(i)).inMilliseconds,
      };
      expect(delays.length, greaterThan(1));
    });

    test('an explicit Retry-After wins over the exponential schedule', () {
      final delay = policy.backoffFor(1,
          retryAfter: const Duration(seconds: 30), random: math.Random(1));
      expect(delay, const Duration(seconds: 30));
    });

    test('Retry-After is read as seconds or as an HTTP date', () {
      expect(RetryPolicy.retryAfterFrom({'retry-after': '42'}),
          const Duration(seconds: 42));

      final soon = DateTime.now().add(const Duration(seconds: 90));
      final parsed =
          RetryPolicy.retryAfterFrom({'retry-after': soon.toIso8601String()});
      expect(parsed!.inSeconds, closeTo(90, 3));

      expect(RetryPolicy.retryAfterFrom({}), isNull);
      expect(RetryPolicy.retryAfterFrom({'retry-after': 'soon-ish'}), isNull);
      expect(
        RetryPolicy.retryAfterFrom({
          'retry-after': DateTime.now()
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
        }),
        Duration.zero,
        reason: 'a date already past means retry now, not travel back in time',
      );
    });
  });
}

class _CountingTranscription extends TranscriptionProvider {
  _CountingTranscription({required this.onStart, required this.onEnd});

  final void Function() onStart;
  final void Function() onEnd;

  @override
  ProviderId get id => const ProviderId('counting');
  @override
  String get displayName => 'Counting';
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
      );
  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'ok');

  @override
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request) async {
    onStart();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    onEnd();
    return [
      TranscriptSegment(
        startMs: request.offsetMs,
        endMs: request.offsetMs + 45000,
        text: 'chunk ${request.offsetMs}',
      ),
    ];
  }
}
