import 'dart:typed_data';

/// Minimal RIFF/WAVE reader and writer.
///
/// The recorder writes one WAV per recording; the chunker needs byte ranges out of it.
/// Rather than pull in an audio library for a 44-byte header, this parses what we write
/// and refuses anything it does not understand — a wrong guess about the format would
/// send silence or noise to a paid transcription API.
class WavFormat {
  const WavFormat({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Byte offset of the first audio sample within the file.
  final int dataOffset;
  final int dataLength;

  int get bytesPerFrame => channels * (bitsPerSample ~/ 8);
  int get bytesPerSecond => sampleRate * bytesPerFrame;

  int get durationMs =>
      bytesPerSecond == 0 ? 0 : (dataLength / bytesPerSecond * 1000).round();

  /// Byte offset of [ms], snapped down to a frame boundary. Cutting mid-frame shifts
  /// every following sample and turns speech into noise.
  int offsetForMs(int ms) {
    final raw = (ms / 1000 * bytesPerSecond).floor();
    return raw - (raw % bytesPerFrame);
  }
}

/// Reads a four-character RIFF chunk id.
String _tag(Uint8List bytes, int at) {
  if (at + 4 > bytes.length) return '';
  return String.fromCharCodes(bytes, at, at + 4);
}

class WavException implements Exception {
  const WavException(this.message);
  final String message;
  @override
  String toString() => 'WavException: $message';
}

/// Reads the header of a WAV file.
///
/// Walks the chunk list rather than assuming a 44-byte header: iOS writes a `LIST`
/// metadata chunk before `data`, so the fixed-offset shortcut silently reads metadata as
/// audio.
WavFormat readWavHeader(Uint8List bytes) {
  if (bytes.length < 12) {
    throw const WavException('file is too short to be a WAV');
  }

  final view = ByteData.sublistView(bytes);
  if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') {
    throw const WavException('not a RIFF/WAVE file');
  }

  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  var cursor = 12;

  while (cursor + 8 <= bytes.length) {
    final id = _tag(bytes, cursor);
    final size = view.getUint32(cursor + 4, Endian.little);
    final body = cursor + 8;

    if (id == 'fmt ') {
      if (body + 16 > bytes.length) {
        throw const WavException('truncated fmt chunk');
      }
      final audioFormat = view.getUint16(body, Endian.little);
      // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE, which is still PCM for our purposes.
      if (audioFormat != 1 && audioFormat != 0xFFFE) {
        throw WavException(
            'unsupported WAV encoding $audioFormat; expected PCM');
      }
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      bitsPerSample = view.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (sampleRate == null || channels == null || bitsPerSample == null) {
        throw const WavException('data chunk appeared before fmt');
      }
      // Some writers leave the size field at 0 or 0xFFFFFFFF when streaming; trust the
      // file length instead of a header that was never finalised.
      final available = bytes.length - body;
      final length = (size == 0 || size > available) ? available : size;
      return WavFormat(
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        dataOffset: body,
        dataLength: length,
      );
    }

    // Chunks are word-aligned: an odd size is followed by a pad byte.
    cursor = body + size + (size.isOdd ? 1 : 0);
  }

  throw const WavException('no data chunk found');
}

/// Wraps raw PCM in a 44-byte canonical WAV header.
Uint8List buildWav({
  required List<int> pcm,
  required int sampleRate,
  required int channels,
  required int bitsPerSample,
}) {
  final bytesPerFrame = channels * (bitsPerSample ~/ 8);
  final out = Uint8List(44 + pcm.length);
  final view = ByteData.sublistView(out);

  void tag(int at, String value) {
    for (var i = 0; i < 4; i++) {
      out[at + i] = value.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  view.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // PCM fmt chunk size
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * bytesPerFrame, Endian.little);
  view.setUint16(32, bytesPerFrame, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  tag(36, 'data');
  view.setUint32(40, pcm.length, Endian.little);
  out.setRange(44, out.length, pcm);

  return out;
}

/// Cuts `[startMs, endMs)` out of a WAV file and returns it as a standalone WAV.
///
/// Providers are handed a complete file, not a naked PCM fragment — Whisper infers the
/// format from the container, and a fragment without a header is rejected or, worse,
/// interpreted at the wrong sample rate.
Uint8List sliceWav(Uint8List source,
    {required int startMs, required int endMs}) {
  final format = readWavHeader(source);
  if (endMs <= startMs) {
    throw WavException('empty slice: ${startMs}ms to ${endMs}ms');
  }

  final from = format.dataOffset + format.offsetForMs(startMs);
  final to = format.dataOffset + format.offsetForMs(endMs);
  final end = format.dataOffset + format.dataLength;

  final clampedFrom = from.clamp(format.dataOffset, end);
  final clampedTo = to.clamp(clampedFrom, end);

  return buildWav(
    pcm: Uint8List.sublistView(source, clampedFrom, clampedTo),
    sampleRate: format.sampleRate,
    channels: format.channels,
    bitsPerSample: format.bitsPerSample,
  );
}
