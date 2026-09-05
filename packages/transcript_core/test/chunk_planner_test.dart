import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  const planner = ChunkPlanner();

  List<SilenceWindow> pausesEvery(int seconds, int upToSeconds) => [
        for (var t = seconds; t < upToSeconds; t += seconds)
          SilenceWindow(t * 1000, t * 1000 + 600),
      ];

  test('a short recording is a single chunk', () {
    final chunks = planner.plan(totalDurationMs: 20000, silences: const []);
    expect(chunks, hasLength(1));
    expect(chunks.single.boundary, ChunkBoundary.end);
    expect(chunks.single.startMs, 0);
    expect(chunks.single.endMs, 20000);
  });

  test('cuts inside a pause when one is available near the target', () {
    // Pause at 44.0-44.6s, target is 45s.
    final chunks = planner.plan(
      totalDurationMs: 200000,
      silences: [const SilenceWindow(44000, 44600)],
    );
    expect(chunks.first.boundary, ChunkBoundary.silence);
    expect(chunks.first.endMs, 44300,
        reason: 'cut lands mid-pause, not at its edge');
  });

  test('picks the pause nearest the target, not the first legal one', () {
    final chunks = planner.plan(
      totalDurationMs: 300000,
      silences: const [
        SilenceWindow(16000, 16800), // legal but far from the 45s target
        SilenceWindow(43000, 43900), // closest
        SilenceWindow(70000, 70800),
      ],
    );
    expect(chunks.first.endMs, 43450);
  });

  test('forces a cut at the ceiling when nobody stops talking', () {
    final chunks = planner.plan(totalDurationMs: 3600000, silences: const []);
    expect(chunks.first.boundary, ChunkBoundary.forced);
    // The ceiling budgets the overlap the next chunk will carry, so the content span is
    // the time cap minus the overlap — otherwise the upload exceeds the byte limit.
    expect(chunks.first.endMs,
        const ChunkerConfig().maxContentDuration.inMilliseconds);
  });

  test('ignores pauses shorter than the silence threshold', () {
    // Twenty minutes with a single 200ms gap: the gap must not be treated as a cut
    // point, so the first chunk runs to the hard ceiling instead.
    final chunks = planner.plan(
      totalDurationMs: 1200000,
      silences: const [
        SilenceWindow(45000, 45200)
      ], // below the 400ms threshold
    );
    expect(chunks.first.boundary, ChunkBoundary.forced,
        reason: 'a 200ms gap is a breath, not a sentence boundary');
    expect(chunks.first.endMs,
        const ChunkerConfig().maxContentDuration.inMilliseconds);
  });

  test('every chunk after the first carries overlap, and the first does not',
      () {
    final chunks =
        planner.plan(totalDurationMs: 300000, silences: pausesEvery(40, 300));
    expect(chunks.first.hasOverlap, isFalse);
    expect(chunks.skip(1),
        everyElement(predicate<PlannedChunk>((c) => c.hasOverlap)));

    for (final c in chunks.skip(1)) {
      expect(c.contentStartMs - c.startMs, 3000);
    }
  });

  test('content boundaries tile the recording with no gaps', () {
    final chunks =
        planner.plan(totalDurationMs: 400000, silences: pausesEvery(37, 400));
    expect(chunks.first.contentStartMs, 0);
    for (var i = 1; i < chunks.length; i++) {
      expect(chunks[i].contentStartMs, chunks[i - 1].endMs,
          reason: 'a gap here means dropped audio');
    }
    expect(chunks.last.endMs, 400000);
  });

  test('the provider byte ceiling binds before the time ceiling', () {
    // 2 MiB at 32 kB/s is 65.5 seconds, well under the 10-minute time cap.
    const config = ChunkerConfig(maxBytes: 2 * 1024 * 1024);
    expect(config.effectiveMaxDuration.inSeconds, 65);
    expect(config.maxContentDuration.inSeconds, 62,
        reason: 'less the 3s overlap');

    final chunks = const ChunkPlanner(config)
        .plan(totalDurationMs: 600000, silences: const []);
    expect(chunks.first.endMs, config.maxContentDuration.inMilliseconds);
  });

  test('forProvider leaves headroom under the advertised limit', () {
    // OpenAI's 25 MB cap, minus room for the container and multipart framing.
    final config = const ChunkerConfig().forProvider(25 * 1024 * 1024);
    expect(config.maxBytes, lessThan(25 * 1024 * 1024));
    expect(config.maxBytes, greaterThan(19 * 1024 * 1024));
  });

  test('a trailing stub is absorbed rather than emitted as its own chunk', () {
    // 48s: one 45s chunk would leave a 3s remainder, too short to transcribe well.
    final chunks = planner.plan(
      totalDurationMs: 48000,
      silences: const [SilenceWindow(44000, 44600)],
    );
    expect(chunks, hasLength(1));
    expect(chunks.single.endMs, 48000);
  });

  test('an empty recording plans nothing', () {
    expect(planner.plan(totalDurationMs: 0, silences: const []), isEmpty);
  });

  test('no chunk ever exceeds the provider byte limit once overlap is counted',
      () {
    // The regression this guards: the planner caps a chunk's new content, but the bytes
    // uploaded are content + overlap. Budgeting only the content overshoots the limit.
    const config = ChunkerConfig(maxBytes: 1024 * 1024);
    final chunks = const ChunkPlanner(config)
        .plan(totalDurationMs: 600000, silences: const []);

    for (final chunk in chunks) {
      final bytes = chunk.durationMs * config.bytesPerSecond ~/ 1000;
      expect(bytes, lessThanOrEqualTo(config.maxBytes),
          reason: 'chunk ${chunk.index} would be rejected by the provider');
    }
  });
}
