import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/recording/recorder_service.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  group('silence detection', () {
    /// Levels sampled every 100ms, as the recorder produces them.
    List<Level> levels(List<double> db) => [
          for (var i = 0; i < db.length; i++) Level(i * 100, db[i]),
        ];

    test('finds a pause between two stretches of speech', () {
      final windows = RecorderService.detectSilences(
        levels([
          ...List.filled(10, -12.0), // 0.0-1.0s speech
          ...List.filled(8, -50.0), // 1.0-1.8s quiet
          ...List.filled(10, -14.0), // 1.8-2.8s speech
        ]),
        2800,
      );

      expect(windows, hasLength(1));
      expect(windows.single.startMs, 1000);
      expect(windows.single.endMs, 1800);
      expect(windows.single.midpointMs, 1400,
          reason: 'the planner cuts mid-pause, not at its edge');
    });

    test('ignores a gap too short to be a sentence boundary', () {
      final windows = RecorderService.detectSilences(
        levels([
          ...List.filled(10, -12.0),
          ...List.filled(2, -50.0), // 200ms — a breath
          ...List.filled(10, -12.0),
        ]),
        2200,
      );
      expect(windows, isEmpty);
    });

    test('a recording that ends on a pause still yields a trailing window', () {
      final windows = RecorderService.detectSilences(
        levels([...List.filled(10, -12.0), ...List.filled(8, -52.0)]),
        1800,
      );
      expect(windows, hasLength(1));
      expect(windows.single.endMs, 1800);
    });

    test('continuous speech yields nothing to cut on', () {
      expect(
        RecorderService.detectSilences(levels(List.filled(40, -15.0)), 4000),
        isEmpty,
      );
    });

    test('a silent recording is one long window, not many', () {
      final windows =
          RecorderService.detectSilences(levels(List.filled(40, -60.0)), 4000);
      expect(windows, hasLength(1));
      expect(windows.single.startMs, 0);
    });

    test('output feeds the chunk planner directly', () {
      // The contract that matters: whatever comes out here is what the planner cuts on.
      final windows = RecorderService.detectSilences(
        levels([
          for (var i = 0; i < 900; i++) (i ~/ 100).isEven ? -12.0 : -50.0,
        ]),
        90000,
      );

      final chunks = const ChunkPlanner()
          .plan(totalDurationMs: 90000, silences: windows);

      expect(chunks, isNotEmpty);
      expect(chunks.every((c) => c.boundary != ChunkBoundary.forced), isTrue,
          reason: 'with pauses this regular, every cut should land in one');
    });
  });

  group('chunk size estimate', () {
    test('matches 16 kHz mono PCM16 at 32 kB per second', () {
      const chunk = PlannedChunk(
        index: 0,
        startMs: 0,
        endMs: 45000,
        contentStartMs: 0,
        boundary: ChunkBoundary.silence,
      );
      expect(WavChunkReader.estimateBytes(chunk), 44 + 45 * 32000);
    });
  });
}
