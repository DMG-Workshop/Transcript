import 'dart:async';

import 'chunk_planner.dart';
import 'chunk_queue.dart';
import 'recording_pipeline.dart';
import 'structuring_pipeline.dart';
import 'transcript.dart';

/// The Phase 2 pipeline: a durable queue feeding the structuring pass.
///
/// Differs from [RecordingPipeline] in exactly one way that matters — nothing is held in
/// memory that has not also been written down. Killing the process at any point and
/// calling [resume] picks up where it stopped, re-uploading only what did not finish.
class DurableRecordingPipeline {
  DurableRecordingPipeline({
    required this.queue,
    required this.structuring,
    this.chunkerConfig = const ChunkerConfig(),
  });

  final ChunkQueue queue;
  final StructuringPipeline structuring;
  final ChunkerConfig chunkerConfig;

  /// Plans the chunks, records them, then runs the queue to completion.
  Stream<PipelineEvent> start({
    required String recordingId,
    required int totalDurationMs,
    required List<SilenceWindow> silences,
    required String referenceDate,
    required String timeZone,
    String? userContext,
    List<TranscriptGap> additionalGaps = const [],
  }) async* {
    final config = chunkerConfig
        .forProvider(queue.transcription.capabilities.maxRequestBytes);
    final plan = ChunkPlanner(config)
        .plan(totalDurationMs: totalDurationMs, silences: silences);

    await queue.enqueue(recordingId, plan);

    yield* _drainAndStructure(
      recordingId: recordingId,
      referenceDate: referenceDate,
      timeZone: timeZone,
      userContext: userContext,
      additionalGaps: additionalGaps,
    );
  }

  /// Picks up a recording whose chunks are already planned.
  ///
  /// Called at launch for anything left unfinished. The user does not have to know the
  /// app was killed — they open it and the notes are being written.
  Stream<PipelineEvent> resume({
    required String recordingId,
    required String referenceDate,
    required String timeZone,
    String? userContext,
    List<TranscriptGap> additionalGaps = const [],
  }) =>
      _drainAndStructure(
        recordingId: recordingId,
        referenceDate: referenceDate,
        timeZone: timeZone,
        userContext: userContext,
        additionalGaps: additionalGaps,
      );

  Stream<PipelineEvent> _drainAndStructure({
    required String recordingId,
    required String referenceDate,
    required String timeZone,
    String? userContext,
    List<TranscriptGap> additionalGaps = const [],
  }) async* {
    final outbox = StreamController<PipelineEvent>();

    // Queue events arrive while drain() is awaited, so they are funnelled through a
    // controller rather than yielded directly.
    final total = (await queue.store.forRecording(recordingId)).length;
    var done = 0;
    outbox.add(TranscribingChunk(completed: 0, total: total));

    final subscription = queue.events.listen((event) {
      switch (event) {
        case QueueSucceeded():
          done++;
          outbox.add(TranscribingChunk(completed: done, total: total));
        case QueueGaveUp(:final index, :final reason):
          done++;
          outbox
            ..add(ChunkFailed(index, reason))
            ..add(TranscribingChunk(completed: done, total: total));
        case QueueStarted() ||
              QueueRetrying() ||
              QueueWaiting() ||
              QueueReclaimed():
          break;
      }
    });

    final drained = queue.drain(recordingId).then((drainedTranscript) async {
      await subscription.cancel();

      // Interruptions are known to the recorder, not to the queue: a phone call takes
      // the microphone without any chunk failing. They are merged in here so the model
      // sees an explicit hole rather than a meeting that appears to skip a beat.
      final transcript = additionalGaps.isEmpty
          ? drainedTranscript
          : Transcript(
              drainedTranscript.segments,
              gaps: [...drainedTranscript.gaps, ...additionalGaps]
                ..sort((a, b) => a.startMs.compareTo(b.startMs)),
            );
      outbox.add(const Structuring());

      try {
        final outcome = await structuring.run(
          transcript: transcript,
          referenceDate: referenceDate,
          timeZone: timeZone,
          sttProviderName: queue.transcription.displayName,
          diarizationAvailable: queue.transcription.capabilities.diarization,
          userContext: userContext,
        );
        outbox.add(PipelineComplete(transcript, outcome));
      } catch (e) {
        // The transcript is already in the database by this point — every chunk was
        // written as it completed — so a model failure costs nothing but the note.
        outbox.add(PipelineFailed(transcript, e));
      }
      await outbox.close();
    });

    yield* outbox.stream;
    await drained;
  }
}
