import 'dart:async';

import '../providers/capabilities.dart';
import '../providers/connection.dart';
import '../providers/provider.dart';
import 'chunk_planner.dart';
import 'structuring_pipeline.dart';
import 'transcript.dart';

/// A transcription source that produces text *while* recording rather than from audio
/// bytes afterwards.
///
/// On-device recognition works this way on both platforms — Apple's `SFSpeechRecognizer`
/// and Android's `SpeechRecognizer` listen to the microphone directly and cannot be handed
/// a file. That makes it a fundamentally different shape from a cloud provider, not just a
/// different implementation, so it gets its own interface rather than being forced through
/// [TranscriptionProvider] with a fake audio argument.
abstract class LiveTranscriptionSource extends AiProvider {
  /// Emits partial and final segments as speech is recognised.
  Stream<TranscriptSegment> get segments;

  Future<void> start({String? languageHint});

  /// Resolves once the final segment has been emitted.
  Future<void> stop();
}

/// Supplies the audio for a planned chunk. Implemented in the app by slicing the
/// recording file; faked in tests, so the pipeline needs no filesystem.
abstract class ChunkAudioReader {
  Future<List<int>> read(PlannedChunk chunk);

  /// MIME type of what [read] returns.
  String get mimeType;
}

/// What the recording screen is showing right now.
sealed class PipelineEvent {
  const PipelineEvent();
}

class TranscribingChunk extends PipelineEvent {
  const TranscribingChunk({required this.completed, required this.total});

  final int completed;
  final int total;

  double get fraction => total == 0 ? 0 : completed / total;
}

/// A chunk failed permanently. The recording continues — this becomes a marked gap.
class ChunkFailed extends PipelineEvent {
  const ChunkFailed(this.index, this.reason);
  final int index;
  final String reason;
}

class Structuring extends PipelineEvent {
  const Structuring();
}

class PipelineComplete extends PipelineEvent {
  const PipelineComplete(this.transcript, this.outcome);
  final Transcript transcript;
  final StructureOutcome outcome;
}

/// Structuring failed, but the transcript survived. The user has not lost their recording
/// and can retry, or retry against a different provider.
class PipelineFailed extends PipelineEvent {
  const PipelineFailed(this.transcript, this.error);
  final Transcript transcript;
  final Object error;
}

/// Drives a finished recording from audio to a structured note.
///
/// Phase 1 runs this after recording stops. The interfaces are already shaped for Phase 2,
/// where the same pipeline consumes a durable queue and runs while the meeting is still
/// going — which is why chunks are addressed by plan rather than by a list of byte arrays.
class RecordingPipeline {
  RecordingPipeline({
    required this.transcription,
    required this.structuring,
    this.chunkerConfig = const ChunkerConfig(),
    this.maxConcurrent = 2,
  });

  final TranscriptionProvider transcription;
  final StructuringPipeline structuring;
  final ChunkerConfig chunkerConfig;

  /// Bounded so a long recording does not trip provider rate limits.
  final int maxConcurrent;

  /// Transcribes every chunk, assembles the result, then structures it.
  ///
  /// Emits progress so the UI can show real state rather than an indeterminate spinner —
  /// on a long recording this takes minutes, and an honest progress bar is the difference
  /// between waiting and force-quitting.
  Stream<PipelineEvent> run({
    required int totalDurationMs,
    required List<SilenceWindow> silences,
    required ChunkAudioReader audio,
    required String referenceDate,
    required String timeZone,
    String? languageHint,
    String? userContext,
  }) async* {
    final config =
        chunkerConfig.forProvider(transcription.capabilities.maxRequestBytes);
    final planned = ChunkPlanner(config)
        .plan(totalDurationMs: totalDurationMs, silences: silences);

    final results = <ChunkTranscript>[];
    var completed = 0;

    yield TranscribingChunk(completed: 0, total: planned.length);

    // Bounded concurrency, in plan order. Results are reordered by index on assembly, so
    // completion order does not matter.
    for (var i = 0; i < planned.length; i += maxConcurrent) {
      final batch = planned.skip(i).take(maxConcurrent).toList();
      final settled = await Future.wait(
        batch.map(
            (chunk) => _transcribeChunk(chunk, audio, results, languageHint)),
      );

      for (final failure in settled.whereType<ChunkFailed>()) {
        yield failure;
      }

      completed += batch.length;
      yield TranscribingChunk(completed: completed, total: planned.length);
    }

    final transcript = const TranscriptAssembler().assemble(results);

    yield const Structuring();
    try {
      final outcome = await structuring.run(
        transcript: transcript,
        referenceDate: referenceDate,
        timeZone: timeZone,
        sttProviderName: transcription.displayName,
        diarizationAvailable: transcription.capabilities.diarization,
        userContext: userContext,
      );
      yield PipelineComplete(transcript, outcome);
    } catch (e) {
      // The transcript is already assembled and the caller persists it before this
      // point, so a structuring failure never costs the recording.
      yield PipelineFailed(transcript, e);
    }
  }

  /// Returns a [ChunkFailed] to report, or null on success. Never throws: one bad chunk
  /// must not fail the recording.
  Future<ChunkFailed?> _transcribeChunk(
    PlannedChunk chunk,
    ChunkAudioReader audio,
    List<ChunkTranscript> into,
    String? languageHint,
  ) async {
    try {
      final bytes = await audio.read(chunk);
      final segments = await transcription.transcribe(TranscribeRequest(
        audio: bytes,
        mimeType: audio.mimeType,
        offsetMs: chunk.startMs,
        languageHint: languageHint,
        primingPrompt: _primingFor(chunk, into),
      ));

      into.add(ChunkTranscript(
        index: chunk.index,
        startMs: chunk.startMs,
        contentStartMs: chunk.contentStartMs,
        endMs: chunk.endMs,
        segments: segments,
      ));
      return null;
    } catch (e) {
      into.add(ChunkTranscript(
        index: chunk.index,
        startMs: chunk.startMs,
        contentStartMs: chunk.contentStartMs,
        endMs: chunk.endMs,
        failed: true,
        error: e.toString(),
      ));
      return ChunkFailed(chunk.index, e.toString());
    }
  }

  /// The tail of the previous chunk, so proper nouns stay spelled consistently across the
  /// seam. Null when the previous chunk has not finished or failed — priming is an
  /// optimisation, never a dependency.
  static String? _primingFor(PlannedChunk chunk, List<ChunkTranscript> done) {
    if (chunk.index == 0) return null;
    for (final candidate in done) {
      if (candidate.index == chunk.index - 1 && !candidate.failed) {
        return Transcript(candidate.segments).primingTail();
      }
    }
    return null;
  }
}

/// Wraps a [LiveTranscriptionSource] so the rest of the app sees one transcription
/// interface.
///
/// Live recognition produces its transcript during recording, so by the time this is
/// asked to transcribe there is nothing left to do — it hands back what it already heard.
/// This is what lets the notes pipeline stay identical whether the user chose on-device
/// recognition or a cloud provider.
class LiveTranscriptionAdapter extends TranscriptionProvider {
  LiveTranscriptionAdapter(this.source);

  final LiveTranscriptionSource source;
  final List<TranscriptSegment> _heard = [];
  StreamSubscription<TranscriptSegment>? _subscription;

  List<TranscriptSegment> get heard => List.unmodifiable(_heard);

  @override
  ProviderId get id => source.id;

  @override
  String get displayName => source.displayName;

  @override
  ProviderCapabilities get capabilities => source.capabilities;

  @override
  bool get isLocalEndpoint => source.isLocalEndpoint;

  @override
  Future<ConnectionResult> test() => source.test();

  Future<void> startListening({String? languageHint}) async {
    _heard.clear();
    _subscription = source.segments.listen(_heard.add);
    await source.start(languageHint: languageHint);
  }

  Future<Transcript> stopListening() async {
    await source.stop();
    await _subscription?.cancel();
    _subscription = null;
    final ordered = [..._heard]..sort((a, b) => a.startMs.compareTo(b.startMs));
    return Transcript(ordered);
  }

  @override
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request) async =>
      _heard.where((s) => s.startMs >= request.offsetMs).toList();
}
