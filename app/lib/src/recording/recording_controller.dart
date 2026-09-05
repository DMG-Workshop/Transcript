import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../settings/provider_config.dart';
import 'on_device_stt.dart';
import 'recorder_service.dart';

/// What the record screen is showing.
sealed class RecordState {
  const RecordState();
}

class RecordIdle extends RecordState {
  const RecordIdle();
}

class RecordActive extends RecordState {
  const RecordActive({required this.elapsed, this.liveText = ''});

  final Duration elapsed;

  /// Live recognition only. Cloud transcription has nothing to show until the recording
  /// stops, and pretending otherwise would be a lie the user notices.
  final String liveText;
}

class RecordProcessing extends RecordState {
  const RecordProcessing({required this.label, this.fraction});

  final String label;

  /// Null when the step has no meaningful progress, such as structuring.
  final double? fraction;
}

class RecordDone extends RecordState {
  const RecordDone(this.recordingId, {this.warning});
  final String recordingId;

  /// Set when the note came back degraded — chunks that failed, quotes that could not
  /// be verified — so the UI can say so rather than presenting it as clean.
  final String? warning;
}

class RecordError extends RecordState {
  const RecordError(this.message, {this.remedy, this.recordingId});
  final String message;
  final String? remedy;

  /// Present when the transcript survived. The recording is not lost.
  final String? recordingId;
}

/// Drives one recording from tapping record to a stored note.
class RecordingController extends StateNotifier<RecordState> {
  RecordingController({
    required RecorderService recorder,
    required RecordingRepository repository,
    required ProviderFactory factory,
    required SettingsStore settings,
  })  : _recorder = recorder,
        _repository = repository,
        _factory = factory,
        _settings = settings,
        super(const RecordIdle());

  final RecorderService _recorder;
  final RecordingRepository _repository;
  final ProviderFactory _factory;
  final SettingsStore _settings;

  LiveTranscriptionAdapter? _live;
  Timer? _ticker;
  String _liveText = '';

  Future<void> startRecording() async {
    try {
      await _recorder.start();
    } on RecorderException catch (e) {
      state = RecordError(e.message, remedy: e.remedy);
      return;
    }

    _liveText = '';
    final transcriptionKind =
        _settings.kindFor(ProviderStage.transcription) ??
            SettingsStore.defaultTranscription;

    if (transcriptionKind == ProviderKind.onDeviceStt) {
      final adapter = LiveTranscriptionAdapter(OnDeviceSpeechSource());
      _live = adapter;
      adapter.source.segments.listen((segment) {
        _liveText = '$_liveText ${segment.text}'.trim();
      });
      await adapter.startListening();
    }

    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (state is RecordActive || state is RecordIdle) {
        state = RecordActive(elapsed: _recorder.elapsed, liveText: _liveText);
      }
    });
    state = RecordActive(elapsed: Duration.zero);
  }

  Future<void> cancelRecording() async {
    _ticker?.cancel();
    await _live?.stopListening();
    _live = null;
    await _recorder.cancel();
    state = const RecordIdle();
  }

  /// Stops, then runs the pipeline. The transcript is persisted before structuring is
  /// attempted, so a model failure never costs the recording.
  Future<void> stopAndProcess() async {
    _ticker?.cancel();

    final captured = await _recorder.stop();
    final liveTranscript = await _live?.stopListening();
    final live = _live;
    _live = null;

    if (captured == null) {
      state = const RecordError('Nothing was recorded.');
      return;
    }

    state = const RecordProcessing(label: 'Preparing');

    final structuringKind = _settings.kindFor(ProviderStage.structuring);
    if (structuringKind == null) {
      state = const RecordError(
        'No note-writing service is set up yet.',
        remedy: 'Choose one in Settings — a model on your own machine works without '
            'a key.',
      );
      return;
    }

    final structuringProvider = await _factory.structuring(ProviderSelection(
      kind: structuringKind,
      hasKey: true,
      endpoint: _settings.endpointFor(structuringKind),
      model: _settings.modelFor(structuringKind),
    ));

    if (structuringProvider == null) {
      state = RecordError(
        '${structuringKind.label} is not configured.',
        remedy: 'Check its key or address in Settings.',
      );
      return;
    }

    final transcriptionProvider = live ??
        await _factory.transcription(ProviderSelection(
          kind: _settings.kindFor(ProviderStage.transcription) ??
              SettingsStore.defaultTranscription,
          hasKey: true,
          model: _settings.modelFor(
              _settings.kindFor(ProviderStage.transcription) ??
                  SettingsStore.defaultTranscription),
        ));

    if (transcriptionProvider == null) {
      state = const RecordError(
        'No transcription service is set up yet.',
        remedy: 'On-device recognition needs no key — choose it in Settings.',
      );
      return;
    }

    final recordingId = await _repository.createRecording(
      path: captured.path,
      duration: captured.duration,
      transcriptionProviderId: transcriptionProvider.id.value,
      structuringProviderId: structuringProvider.id.value,
    );

    if (liveTranscript != null) {
      await _repository.saveTranscript(recordingId, liveTranscript);
    }

    final pipeline = RecordingPipeline(
      transcription: transcriptionProvider,
      structuring: StructuringPipeline(provider: structuringProvider),
    );

    final now = DateTime.now();
    await for (final event in pipeline.run(
      totalDurationMs: captured.duration.inMilliseconds,
      silences: captured.silences,
      audio: WavChunkReader(File(captured.path)),
      referenceDate: _isoDate(now),
      timeZone: now.timeZoneName,
    )) {
      switch (event) {
        case TranscribingChunk(:final completed, :final total):
          state = RecordProcessing(
            label: total <= 1
                ? 'Transcribing'
                : 'Transcribing $completed of $total',
            fraction: event.fraction,
          );
        case ChunkFailed():
          break; // reported in the warning below, not as a modal interruption
        case Structuring():
          state = const RecordProcessing(label: 'Writing notes');
        case PipelineComplete(:final transcript, :final outcome):
          await _repository.saveTranscript(recordingId, transcript);
          await _repository.saveNote(recordingId, outcome);
          state = RecordDone(recordingId, warning: _warningFor(transcript, outcome));
        case PipelineFailed(:final transcript, :final error):
          await _repository.saveTranscript(recordingId, transcript);
          state = RecordError(
            'The notes could not be written.',
            remedy: 'Your recording and transcript are saved. Try again, or switch to '
                'a different service in Settings.',
            recordingId: recordingId,
          );
          assert(() {
            // Surfaced in debug builds only; the message above is what users see.
            // ignore: avoid_print
            print('structuring failed: $error');
            return true;
          }());
      }
    }
  }

  /// An honest one-liner about what is imperfect in this note, or null if nothing is.
  static String? _warningFor(Transcript transcript, StructureOutcome outcome) {
    final parts = <String>[
      if (transcript.gaps.isNotEmpty)
        '${transcript.gaps.length} section${transcript.gaps.length == 1 ? '' : 's'} '
            'could not be transcribed',
      if (outcome.unverifiedQuotes.isNotEmpty)
        '${outcome.unverifiedQuotes.length} item${outcome.unverifiedQuotes.length == 1 ? '' : 's'} '
            'could not be traced back to the recording',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

final databaseProvider = Provider<TranscriptDatabase>((ref) {
  final db = TranscriptDatabase();
  ref.onDispose(db.close);
  return db;
});

final repositoryProvider = Provider<RecordingRepository>(
  (ref) => RecordingRepository(ref.watch(databaseProvider)),
);

final recorderProvider = Provider<RecorderService>((ref) {
  final recorder = RecorderService();
  ref.onDispose(recorder.dispose);
  return recorder;
});

final recordingsProvider = StreamProvider<List<Recording>>(
  (ref) => ref.watch(repositoryProvider).watchAll(),
);

/// SharedPreferences is async to open, so the app awaits it once at startup and
/// overrides this provider with the resolved instance. Reading it before that is a
/// programming error, not a runtime condition to handle.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw UnimplementedError('settingsStoreProvider must be overridden'),
);

final recordingControllerProvider =
    StateNotifierProvider<RecordingController, RecordState>(
  (ref) => RecordingController(
    recorder: ref.watch(recorderProvider),
    repository: ref.watch(repositoryProvider),
    factory: ref.watch(providerFactoryProvider),
    settings: ref.watch(settingsStoreProvider),
  ),
);
