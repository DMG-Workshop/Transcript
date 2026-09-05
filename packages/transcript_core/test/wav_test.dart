import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  /// One second of 16 kHz mono PCM16, with each frame numbered so slices are traceable.
  Uint8List oneSecond({int seconds = 1}) {
    final frames = 16000 * seconds;
    final pcm = Uint8List(frames * 2);
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < frames; i++) {
      view.setInt16(i * 2, i % 32000, Endian.little);
    }
    return buildWav(
        pcm: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16);
  }

  group('header', () {
    test('reads the format the recorder writes', () {
      final format = readWavHeader(oneSecond(seconds: 3));
      expect(format.sampleRate, 16000);
      expect(format.channels, 1);
      expect(format.bitsPerSample, 16);
      expect(format.dataOffset, 44);
      expect(format.durationMs, 3000);
      expect(format.bytesPerSecond, 32000,
          reason:
              '16 kHz mono PCM16 is 32 kB/s — the number the chunker budgets with');
    });

    test('walks past a LIST chunk instead of assuming a 44-byte header', () {
      // iOS writes metadata before `data`; a fixed offset would read it as audio.
      final base = oneSecond();
      final list = Uint8List(20);
      final listView = ByteData.sublistView(list);
      for (var i = 0; i < 4; i++) {
        list[i] = 'LIST'.codeUnitAt(i);
      }
      listView.setUint32(4, 12, Endian.little);

      final withList = Uint8List(base.length + list.length)
        ..setRange(0, 36, base) // RIFF + fmt
        ..setRange(36, 36 + list.length, list)
        ..setRange(36 + list.length, base.length + list.length,
            Uint8List.sublistView(base, 36));

      final format = readWavHeader(withList);
      expect(format.dataOffset, 44 + list.length);
      expect(format.sampleRate, 16000);
    });

    test('trusts the file length when the size field was never finalised', () {
      // A recording interrupted by a crash leaves the data size at zero.
      final bytes = oneSecond();
      ByteData.sublistView(bytes).setUint32(40, 0, Endian.little);
      expect(readWavHeader(bytes).dataLength, 32000);
    });

    test('rejects a non-PCM encoding rather than sending noise to a paid API',
        () {
      final bytes = oneSecond();
      ByteData.sublistView(bytes)
          .setUint16(20, 0x0011, Endian.little); // IMA ADPCM
      expect(() => readWavHeader(bytes), throwsA(isA<WavException>()));
    });

    test('rejects a file that is not a WAV at all', () {
      expect(() => readWavHeader(Uint8List.fromList('not audio'.codeUnits)),
          throwsA(isA<WavException>()));
    });
  });

  group('slicing', () {
    test('produces a playable WAV, not a naked fragment', () {
      final slice =
          sliceWav(oneSecond(seconds: 10), startMs: 2000, endMs: 5000);
      final format = readWavHeader(slice);

      expect(format.dataOffset, 44, reason: 'the slice carries its own header');
      expect(format.sampleRate, 16000);
      expect(format.durationMs, 3000);
    });

    test('cuts at the right bytes', () {
      final source = oneSecond(seconds: 4);
      final slice = sliceWav(source, startMs: 1000, endMs: 2000);

      // Frame 16000 is the first sample of the second second.
      final sliced = ByteData.sublistView(slice, 44);
      expect(sliced.getInt16(0, Endian.little), 16000 % 32000);
      expect(slice.length - 44, 32000);
    });

    test(
        'snaps to a frame boundary — an odd byte offset turns speech into noise',
        () {
      final format = readWavHeader(oneSecond());
      // 1.000031ms would land mid-frame at 16 kHz PCM16.
      expect(format.offsetForMs(1) % format.bytesPerFrame, 0);
      expect(format.offsetForMs(333) % format.bytesPerFrame, 0);
      expect(format.offsetForMs(7777) % format.bytesPerFrame, 0);
    });

    test('a slice past the end of the recording is clamped, not out of range',
        () {
      final slice = sliceWav(oneSecond(seconds: 2), startMs: 1500, endMs: 9000);
      expect(readWavHeader(slice).durationMs, 500);
    });

    test('a slice entirely past the end yields an empty but valid WAV', () {
      final slice = sliceWav(oneSecond(seconds: 2), startMs: 5000, endMs: 6000);
      final format = readWavHeader(slice);
      expect(format.dataLength, 0);
      expect(format.sampleRate, 16000, reason: 'still a well-formed file');
    });

    test('an inverted range is refused rather than silently returning nothing',
        () {
      expect(() => sliceWav(oneSecond(), startMs: 900, endMs: 100),
          throwsA(isA<WavException>()));
    });

    test('round-trips through the chunk planner byte budget', () {
      // A 3-minute recording at the OpenAI ceiling: every slice must stay under it.
      final source = oneSecond(seconds: 180);
      final config = const ChunkerConfig().forProvider(25 * 1024 * 1024);
      final chunks = ChunkPlanner(config)
          .plan(totalDurationMs: 180000, silences: const []);

      for (final chunk in chunks) {
        final slice =
            sliceWav(source, startMs: chunk.startMs, endMs: chunk.endMs);
        expect(slice.length, lessThanOrEqualTo(config.maxBytes));
        expect(readWavHeader(slice).durationMs, closeTo(chunk.durationMs, 2));
      }
    });
  });
}
