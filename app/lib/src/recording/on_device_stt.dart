import 'dart:async';

import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:transcript_core/transcript_core.dart';

/// On-device speech recognition, wrapped as a [LiveTranscriptionSource].
///
/// This is the configuration that makes the app usable before the user has pasted
/// anything: free, offline, and the audio never leaves the phone. It is also the reason
/// live transcription is a separate interface — Apple's `SFSpeechRecognizer` and
/// Android's `SpeechRecognizer` listen to the microphone directly and cannot be handed a
/// file, so they can never implement [TranscriptionProvider].
class OnDeviceSpeechSource extends LiveTranscriptionSource {
  OnDeviceSpeechSource({stt.SpeechToText? speech, DateTime Function()? clock})
      : _speech = speech ?? stt.SpeechToText(),
        _now = clock ?? DateTime.now;

  /// Both platforms end a listening session after a stretch of silence, and iOS caps a
  /// single utterance at around a minute. A meeting has many such pauses, so the session
  /// is restarted until the caller says stop — without this the transcript ends at the
  /// first thoughtful pause.
  static const Duration _sessionLength = Duration(minutes: 1);
  static const Duration _pauseTolerance = Duration(seconds: 30);

  final stt.SpeechToText _speech;
  final DateTime Function() _now;
  final _segments = StreamController<TranscriptSegment>.broadcast();

  DateTime? _startedAt;
  bool _stopping = false;
  int _lastFinalEndMs = 0;

  @override
  Stream<TranscriptSegment> get segments => _segments.stream;

  @override
  ProviderId get id => const ProviderId('on-device');

  @override
  String get displayName => 'On-device recognition';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        // Neither platform exposes speaker labels. Users ask for this constantly; the
        // honest answer is that it needs a separate diarization model.
        diarization: false,
        wordTimestamps: false,
        streaming: true,
        requiresApiKey: false,
        runsOnDevice: true,
      );

  @override
  Future<ConnectionResult> test() async {
    final available = await _speech.initialize(
      onError: (_) {},
      onStatus: (_) {},
      debugLogging: false,
    );

    if (!available) {
      return ConnectionResult.failure(
        summary: 'Speech recognition is unavailable on this device',
        remedy: 'Check that dictation is enabled in system settings, or choose a '
            'cloud provider instead.',
      );
    }

    final locales = await _speech.locales();
    return ConnectionResult.success(
      summary: 'Ready · on-device · ${locales.length} languages',
      models: locales.take(8).map((l) => l.localeId).toList(),
    );
  }

  @override
  Future<void> start({String? languageHint}) async {
    if (!await _speech.initialize(onError: _onError, onStatus: _onStatus)) {
      throw StateError('Speech recognition is unavailable on this device.');
    }
    _startedAt = _now();
    _stopping = false;
    _lastFinalEndMs = 0;
    await _listen(languageHint);
  }

  Future<void> _listen(String? languageHint) => _speech.listen(
        onResult: _onResult,
        listenOptions: stt.SpeechListenOptions(
          listenFor: _sessionLength,
          pauseFor: _pauseTolerance,
          partialResults: true,
          // Prefer on-device recognition where the platform offers it, so nothing is
          // sent to the vendor's servers. Falls back automatically where it is not.
          onDevice: true,
          cancelOnError: false,
          listenMode: stt.ListenMode.dictation,
          localeId: languageHint,
        ),
      );

  @override
  Future<void> stop() async {
    _stopping = true;
    await _speech.stop();
    // Give the platform a moment to deliver the final result before closing the stream,
    // or the last sentence of the meeting is lost.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _segments.close();
    _startedAt = null;
  }

  void _onResult(SpeechRecognitionResult result) {
    if (!result.finalResult || result.recognizedWords.trim().isEmpty) return;

    final endMs = _elapsedMs();
    _segments.add(TranscriptSegment(
      startMs: _lastFinalEndMs,
      endMs: endMs,
      text: result.recognizedWords.trim(),
    ));
    _lastFinalEndMs = endMs;
  }

  /// Restarts the session when the platform ends one on its own. This is the difference
  /// between transcribing a meeting and transcribing its first minute.
  void _onStatus(String status) {
    if (_stopping) return;
    if (status == 'done' || status == 'notListening') {
      unawaited(_listen(null));
    }
  }

  void _onError(Object error) {
    // A no-match error just means nobody spoke during that session; restarting is the
    // correct response, not surfacing an error to the user mid-meeting.
    if (_stopping) return;
    unawaited(_listen(null));
  }

  int _elapsedMs() =>
      _startedAt == null ? 0 : _now().difference(_startedAt!).inMilliseconds;
}
