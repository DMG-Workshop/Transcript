import 'dart:async';

import '../providers/capabilities.dart';
import '../providers/connection.dart';
import '../providers/provider.dart';
import 'whisper_models.dart';

/// The native side of whisper.cpp, behind an interface.
///
/// The actual work — loading a ggml model and decoding PCM — happens in a native library
/// reached over FFI, which cannot run or be tested in a pure-Dart environment. Keeping it
/// behind this seam means the provider, its capability reporting, and its error handling
/// are all testable with a fake, and the one genuinely-native, genuinely-unverifiable
/// piece is small and isolated.
abstract class WhisperEngine {
  /// Whether a usable model file is present on disk for [modelId].
  Future<bool> isModelReady(String modelId);

  /// Absolute path to the model file, or null if it is not downloaded.
  Future<String?> modelPath(String modelId);

  /// Transcribes 16 kHz mono PCM16 audio, offline.
  Future<List<TranscriptSegment>> transcribe({
    required String modelPath,
    required List<int> pcm16,
    String? languageHint,
  });
}

/// A fully offline transcription provider backed by a bundled whisper.cpp model.
///
/// Fits [TranscriptionProvider] rather than [LiveTranscriptionSource]: whisper.cpp
/// decodes a buffer, it does not listen to a microphone, so the recording is transcribed
/// after it stops, chunk by chunk, exactly like a cloud provider — but with nothing
/// leaving the phone.
class WhisperTranscriptionProvider extends TranscriptionProvider {
  WhisperTranscriptionProvider({
    required WhisperEngine engine,
    required this.model,
  }) : _engine = engine;

  final WhisperEngine _engine;
  final WhisperModel model;

  @override
  ProviderId get id => ProviderId('whisper:${model.id}');

  @override
  String get displayName => 'Whisper ${model.label} (offline)';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        wordTimestamps: true,
        requiresApiKey: false,
        runsOnDevice: true,
        // No network request, so no request-size limit. The chunker still splits for
        // failure isolation and memory, not for an upload cap.
        maxRequestBytes: 0,
      );

  @override
  Future<ConnectionResult> test() async {
    if (!await _engine.isModelReady(model.id)) {
      return ConnectionResult.failure(
        summary: 'The ${model.label} model is not downloaded yet',
        remedy: 'Download it in settings — it is about '
            '${model.approxMegabytes.round()} MB and only needs fetching once.',
      );
    }
    return ConnectionResult.success(
      summary: 'Ready · ${model.label} · fully offline',
    );
  }

  @override
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request) async {
    final path = await _engine.modelPath(model.id);
    if (path == null) {
      throw StateError(
        'The ${model.label} model is not downloaded. This should have been caught '
        'before recording started.',
      );
    }

    final segments = await _engine.transcribe(
      modelPath: path,
      pcm16: request.audio,
      languageHint: request.languageHint,
    );

    // whisper returns offsets relative to the buffer it was given; shift them to
    // absolute positions in the recording so sourceRef offsets stay meaningful.
    return segments.map((s) => s.shifted(request.offsetMs)).toList();
  }
}
