import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'transcript_whisper_native_bindings_generated.dart';

/// One decoded segment from a whisper.cpp transcription.
class WhisperNativeSegment {
  const WhisperNativeSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

/// Thrown when the native library reports a transcription failure (a bad
/// WAV file, a model that failed to load, or a whisper.cpp decode error).
class WhisperNativeException implements Exception {
  const WhisperNativeException(this.message);

  final String message;

  @override
  String toString() => 'WhisperNativeException: $message';
}

/// Transcribes [wavPath] (which must already be 16 kHz mono 16-bit PCM WAV —
/// exactly what `transcript_core`'s WAV builder produces, so no ffmpeg or
/// other re-encoding step is needed) using the ggml/whisper.cpp model at
/// [modelPath].
///
/// Runs on a fresh helper isolate via [Isolate.run] so the caller's isolate
/// is never blocked by what can be a multi-second CPU-bound decode. The
/// native library keeps the most recently used model resident across calls
/// (including calls from different helper isolates spawned this way, since
/// the loaded native library is shared process-wide), so a sequence of
/// chunks from the same recording only pays the model-load cost once.
///
/// [libraryPath], if given, loads the native library from that exact path
/// instead of the platform-conventional plugin location. Tests use this to
/// point at a freshly built library; app code should never need it.
Future<List<WhisperNativeSegment>> transcribeWav({
  required String modelPath,
  required String wavPath,
  String? languageHint,
  int threads = 4,
  String? libraryPath,
}) {
  return Isolate.run(
    () => transcribeWavSync(
      modelPath: modelPath,
      wavPath: wavPath,
      languageHint: languageHint,
      threads: threads,
      libraryPath: libraryPath,
    ),
  );
}

/// Synchronous form of [transcribeWav]. Prefer [transcribeWav] unless the
/// caller already runs on a dedicated background isolate (for example, the
/// app's own chunk-processing isolate).
List<WhisperNativeSegment> transcribeWavSync({
  required String modelPath,
  required String wavPath,
  String? languageHint,
  int threads = 4,
  String? libraryPath,
}) {
  final bindings = _bindingsFor(libraryPath);
  final modelPathPtr = modelPath.toNativeUtf8();
  final wavPathPtr = wavPath.toNativeUtf8();
  final languagePtr = (languageHint == null || languageHint.isEmpty)
      ? nullptr
      : languageHint.toNativeUtf8();
  try {
    final resultPtr = bindings.transcript_whisper_transcribe(
      modelPathPtr.cast(),
      wavPathPtr.cast(),
      languagePtr == nullptr ? nullptr : languagePtr.cast(),
      threads,
    );
    if (resultPtr == nullptr) {
      throw const WhisperNativeException(
        'native transcription returned no result',
      );
    }
    try {
      final jsonText = resultPtr.cast<Utf8>().toDartString();
      return _parseResponse(jsonText);
    } finally {
      bindings.transcript_whisper_free_string(resultPtr.cast());
    }
  } finally {
    malloc.free(modelPathPtr);
    malloc.free(wavPathPtr);
    if (languagePtr != nullptr) {
      malloc.free(languagePtr);
    }
  }
}

List<WhisperNativeSegment> _parseResponse(String jsonText) {
  final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
  final error = decoded['error'];
  if (error != null) {
    throw WhisperNativeException(error as String);
  }
  final rawSegments = decoded['segments'] as List<dynamic>? ?? const [];
  return rawSegments
      .map((raw) {
        final map = raw as Map<String, dynamic>;
        return WhisperNativeSegment(
          startMs: (map['start_ms'] as num).toInt(),
          endMs: (map['end_ms'] as num).toInt(),
          text: map['text'] as String,
        );
      })
      .toList(growable: false);
}

/// Releases the resident native model context, if any. Safe to call even
/// when nothing is loaded; useful when switching models or freeing memory
/// once offline transcription is no longer needed.
void releaseWhisperModel({String? libraryPath}) =>
    _bindingsFor(libraryPath).transcript_whisper_release();

/// The native library's self-reported version string, for diagnostics.
String whisperNativeVersion({String? libraryPath}) =>
    _bindingsFor(libraryPath)
        .transcript_whisper_version()
        .cast<Utf8>()
        .toDartString();

const String _libName = 'transcript_whisper_native';

/// The dynamic library in which the symbols for [TranscriptWhisperNativeBindings] can be found.
final DynamicLibrary _defaultDylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// The bindings to the native functions in [_defaultDylib].
final TranscriptWhisperNativeBindings _defaultBindings =
    TranscriptWhisperNativeBindings(_defaultDylib);

TranscriptWhisperNativeBindings _bindingsFor(String? libraryPath) {
  if (libraryPath == null) {
    return _defaultBindings;
  }
  return TranscriptWhisperNativeBindings(DynamicLibrary.open(libraryPath));
}
