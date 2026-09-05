import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:transcript_core/transcript_core.dart';

/// Captures audio to a WAV file and tracks loudness while it does.
///
/// Always 16 kHz mono PCM16. Every speech-to-text engine resamples to that internally, so
/// recording at 44.1 kHz stereo triples the upload for no accuracy gain: 32 kB/s, which is
/// exactly the figure the chunk planner budgets with.
class RecorderService {
  RecorderService({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  static const RecordConfig config = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
    // Meetings are the target: level the speakers at the far end of the table without
    // amplifying the room between sentences.
    autoGain: true,
    echoCancel: true,
    noiseSuppress: true,
  );

  /// Sampling interval for the level meter. Fast enough to look alive, slow enough that
  /// an hour of recording does not accumulate an unbounded list.
  static const Duration amplitudeInterval = Duration(milliseconds: 100);

  /// Below this, in dBFS, the room counts as quiet. Chosen above the noise floor of a
  /// phone microphone in a normal room; the chunker only needs approximate boundaries.
  static const double silenceThresholdDb = -38;

  final AudioRecorder _recorder;

  final _levels = StreamController<double>.broadcast();
  final List<Level> _history = [];

  StreamSubscription<Amplitude>? _amplitudeSubscription;
  DateTime? _startedAt;
  String? _path;

  /// Normalised 0..1 loudness, for the waveform.
  Stream<double> get levels => _levels.stream;

  bool get isRecording => _startedAt != null;

  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw const RecorderException(
        'Microphone access was declined.',
        'Transcript cannot record without it. You can grant access in Settings.',
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final recordings = Directory(p.join(dir.path, 'recordings'));
    if (!recordings.existsSync()) recordings.createSync(recursive: true);

    _path = p.join(
      recordings.path,
      'rec_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    _history.clear();

    await _recorder.start(config, path: _path!);
    _startedAt = DateTime.now();

    _amplitudeSubscription =
        _recorder.onAmplitudeChanged(amplitudeInterval).listen((amplitude) {
      final atMs = elapsed.inMilliseconds;
      _history.add(Level(atMs, amplitude.current));
      _levels.add(_normalise(amplitude.current));
    });
  }

  /// Stops and returns what was captured, or null if nothing was.
  Future<CapturedAudio?> stop() async {
    if (_startedAt == null) return null;

    final duration = elapsed;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    final path = await _recorder.stop();
    _startedAt = null;
    if (path == null) return null;

    return CapturedAudio(
      path: path,
      duration: duration,
      silences: detectSilences(_history, duration.inMilliseconds),
    );
  }

  Future<void> cancel() async {
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    _startedAt = null;
    await _recorder.cancel();
  }

  Future<void> dispose() async {
    await _amplitudeSubscription?.cancel();
    await _levels.close();
    await _recorder.dispose();
  }

  /// dBFS is roughly -60 (silence) to 0 (clipping); the top third is where speech lives.
  static double _normalise(double db) =>
      ((db + 55) / 55).clamp(0.0, 1.0).toDouble();

  /// Turns the level history into the silence windows the chunk planner cuts on.
  ///
  /// This is not a real VAD — it is an energy gate, which is enough to find the gaps
  /// between sentences and costs nothing, since the level meter is already running for the
  /// waveform. A proper VAD arrives in Phase 2 alongside the streaming chunker.
  static List<SilenceWindow> detectSilences(
    List<Level> history,
    int totalDurationMs, {
    double thresholdDb = silenceThresholdDb,
    int minSilenceMs = 400,
  }) {
    final windows = <SilenceWindow>[];
    int? quietSince;

    for (final level in history) {
      if (level.db <= thresholdDb) {
        quietSince ??= level.atMs;
      } else if (quietSince != null) {
        if (level.atMs - quietSince >= minSilenceMs) {
          windows.add(SilenceWindow(quietSince, level.atMs));
        }
        quietSince = null;
      }
    }

    // Trailing silence, if the recording ended on a pause.
    if (quietSince != null && totalDurationMs - quietSince >= minSilenceMs) {
      windows.add(SilenceWindow(quietSince, totalDurationMs));
    }
    return windows;
  }

  /// Loudness history, for tests and for drawing the finished waveform.
  List<double> get waveform =>
      _history.map((l) => _normalise(l.db)).toList(growable: false);
}

/// One loudness sample. Public because [RecorderService.detectSilences] is a pure
/// function tested directly.
class Level {
  const Level(this.atMs, this.db);
  final int atMs;
  final double db;
}

/// What the recorder captured. Named to avoid colliding with drift's generated
/// `Recording` row class, which is the persisted form of the same thing.
class CapturedAudio {
  const CapturedAudio({
    required this.path,
    required this.duration,
    required this.silences,
  });

  final String path;
  final Duration duration;

  /// Where the chunk planner may cut without splitting a word.
  final List<SilenceWindow> silences;
}

class RecorderException implements Exception {
  const RecorderException(this.message, [this.remedy]);
  final String message;
  final String? remedy;
  @override
  String toString() => message;
}

/// Reads chunk audio out of a finished WAV recording.
///
/// Each chunk is handed to the provider as a complete WAV file, not a naked PCM
/// fragment — Whisper infers the format from the container.
class WavChunkReader implements ChunkAudioReader {
  WavChunkReader(this.file);

  final File file;
  Uint8ListCache? _cache;

  @override
  String get mimeType => 'audio/wav';

  @override
  Future<List<int>> read(PlannedChunk chunk) async {
    // The whole recording is read once and sliced many times: an hour of 16 kHz mono is
    // ~115 MB, which is too much to hold for a long recording, so Phase 2 moves this to
    // a random-access read. For Phase 1's short recordings, one read is simpler.
    final bytes = _cache ??= Uint8ListCache(await file.readAsBytes());
    return sliceWav(bytes.value, startMs: chunk.startMs, endMs: chunk.endMs);
  }

  /// Approximate size of a chunk, for the cost meter, without reading the file.
  static int estimateBytes(PlannedChunk chunk) =>
      44 + (chunk.durationMs * 32000 / 1000).round();

  static double approximateMinutes(int bytes) =>
      math.max(0, (bytes - 44) / 32000 / 60);
}

/// Tiny holder so the cached bytes are nullable without losing the non-null type.
class Uint8ListCache {
  const Uint8ListCache(this.value);
  final Uint8List value;
}
