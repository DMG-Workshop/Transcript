import 'dart:async';
import 'dart:math' as math;

import '../providers/errors.dart';
import '../providers/http_transport.dart';
import '../providers/provider.dart';
import 'chunk_planner.dart';
import 'recording_pipeline.dart';
import 'transcript.dart';

/// Lifecycle of one chunk. Terminal states are [transcribed] and [failed].
enum ChunkState {
  pending,
  uploading,

  /// A retryable failure. [ChunkRecord.nextAttemptAt] says when to try again.
  backoff,

  transcribed,

  /// Permanently failed. Becomes a marked gap in the transcript, never a failed
  /// recording.
  failed,
}

/// A chunk as it is stored. Deliberately a plain value: the queue's whole point is that
/// its state lives in a database rather than in memory, so this has to survive being
/// written out and read back.
class ChunkRecord {
  const ChunkRecord({
    required this.id,
    required this.recordingId,
    required this.index,
    required this.startMs,
    required this.contentStartMs,
    required this.endMs,
    this.state = ChunkState.pending,
    this.attempts = 0,
    this.nextAttemptAt,
    this.segments = const [],
    this.error,
  });

  factory ChunkRecord.fromPlan(String recordingId, PlannedChunk plan) =>
      ChunkRecord(
        id: '${recordingId}_c${plan.index}',
        recordingId: recordingId,
        index: plan.index,
        startMs: plan.startMs,
        contentStartMs: plan.contentStartMs,
        endMs: plan.endMs,
      );

  final String id;
  final String recordingId;
  final int index;
  final int startMs;
  final int contentStartMs;
  final int endMs;
  final ChunkState state;
  final int attempts;
  final DateTime? nextAttemptAt;
  final List<TranscriptSegment> segments;
  final String? error;

  bool get isTerminal =>
      state == ChunkState.transcribed || state == ChunkState.failed;

  PlannedChunk get plan => PlannedChunk(
        index: index,
        startMs: startMs,
        endMs: endMs,
        contentStartMs: contentStartMs,
        boundary: ChunkBoundary.silence,
      );

  ChunkTranscript get asTranscript => ChunkTranscript(
        index: index,
        startMs: startMs,
        contentStartMs: contentStartMs,
        endMs: endMs,
        segments: segments,
        failed: state == ChunkState.failed,
        error: error,
      );

  ChunkRecord copyWith({
    ChunkState? state,
    int? attempts,
    Object? nextAttemptAt = _unset,
    List<TranscriptSegment>? segments,
    Object? error = _unset,
  }) =>
      ChunkRecord(
        id: id,
        recordingId: recordingId,
        index: index,
        startMs: startMs,
        contentStartMs: contentStartMs,
        endMs: endMs,
        state: state ?? this.state,
        attempts: attempts ?? this.attempts,
        nextAttemptAt: identical(nextAttemptAt, _unset)
            ? this.nextAttemptAt
            : nextAttemptAt as DateTime?,
        segments: segments ?? this.segments,
        error: identical(error, _unset) ? this.error : error as String?,
      );
}

const Object _unset = Object();

/// Where chunk state is persisted. Implemented over SQLite in the app; faked in tests,
/// which is how "the app was killed mid-upload" becomes something we can actually assert
/// on rather than hope about.
abstract class ChunkStore {
  Future<void> putAll(List<ChunkRecord> chunks);
  Future<void> update(ChunkRecord chunk);
  Future<List<ChunkRecord>> forRecording(String recordingId);
}

/// When to retry, and when to stop.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.base = const Duration(seconds: 2),
    this.cap = const Duration(minutes: 5),
  });

  /// Total tries per chunk, including the first. Past this the chunk becomes a gap —
  /// one unreachable minute of a meeting is not worth blocking the other fifty-nine.
  final int maxAttempts;

  final Duration base;
  final Duration cap;

  /// Exponential backoff with jitter, honouring an explicit `Retry-After` when the
  /// provider sent one — guessing shorter than a rate limiter asked for gets the next
  /// request rejected too.
  Duration backoffFor(int attempt,
      {Duration? retryAfter, math.Random? random}) {
    if (retryAfter != null) return retryAfter;
    final exponential = base * math.pow(2, math.max(0, attempt - 1)).toDouble();
    final bounded = exponential > cap ? cap : exponential;
    // Jitter up to 25%, so a batch of chunks that failed together does not retry in
    // lockstep and trip the same rate limit again.
    final jitter = (random ?? math.Random()).nextDouble() * 0.25;
    return Duration(
      milliseconds: (bounded.inMilliseconds * (1 + jitter)).round(),
    );
  }

  /// Whether this failure is worth trying again.
  ///
  /// The distinction that matters: a rejected key or a malformed request will fail
  /// identically forever, and retrying it five times only wastes the user's time and
  /// their API credit.
  bool isRetryable(Object error) {
    if (error is TransportException) return true; // networks come back
    if (error is ProviderException) {
      return switch (error.statusCode) {
        408 || 425 || 429 => true,
        >= 500 => true,
        // 0 is a client-side rejection the adapter raised before sending, such as an
        // oversized chunk. That will not change on its own.
        _ => false,
      };
    }
    // A bug or a corrupt file. Retrying will not help and hides the cause.
    return false;
  }

  /// `Retry-After` as seconds or an HTTP date. Absent or unparseable means fall back to
  /// the exponential schedule.
  static Duration? retryAfterFrom(Map<String, String> headers) {
    final raw = headers['retry-after'] ?? headers['Retry-After'];
    if (raw == null) return null;

    final seconds = int.tryParse(raw.trim());
    if (seconds != null) return Duration(seconds: seconds);

    final date = DateTime.tryParse(raw.trim());
    if (date == null) return null;
    final delta = date.difference(DateTime.now());
    return delta.isNegative ? Duration.zero : delta;
  }
}

/// A durable, resumable transcription queue.
///
/// This is the difference between a demo and a product. The OS kills the app, the network
/// drops, the battery dies mid-meeting — on relaunch the queue reloads from the store and
/// re-uploads only what did not finish. Nothing here holds work in memory that it has not
/// also written down.
class ChunkQueue {
  ChunkQueue({
    required this.store,
    required this.transcription,
    required this.audio,
    this.policy = const RetryPolicy(),
    this.maxConcurrent = 2,
    this.languageHint,
    DateTime Function()? clock,
    math.Random? random,
  })  : _now = clock ?? DateTime.now,
        _random = random ?? math.Random();

  final ChunkStore store;
  final TranscriptionProvider transcription;
  final ChunkAudioReader audio;
  final RetryPolicy policy;

  /// Bounded so a long recording does not trip provider rate limits.
  final int maxConcurrent;

  final String? languageHint;
  final DateTime Function() _now;
  final math.Random _random;

  final _events = StreamController<QueueEvent>.broadcast();
  Stream<QueueEvent> get events => _events.stream;

  /// Registers a plan. Safe to call again for the same recording: chunks already stored
  /// keep their state, so a crash between planning and the first upload does not restart
  /// finished work.
  Future<void> enqueue(String recordingId, List<PlannedChunk> plan) async {
    final existing = {
      for (final chunk in await store.forRecording(recordingId))
        chunk.index: chunk,
    };
    final fresh = [
      for (final item in plan)
        if (!existing.containsKey(item.index))
          ChunkRecord.fromPlan(recordingId, item),
    ];
    if (fresh.isNotEmpty) await store.putAll(fresh);
  }

  /// Works the queue until every chunk is terminal.
  ///
  /// Returns the assembled transcript, gaps included. Never throws for a chunk failure:
  /// that is what [ChunkState.failed] and [Transcript.gaps] are for.
  Future<Transcript> drain(String recordingId) async {
    while (true) {
      final all = await store.forRecording(recordingId);
      if (all.every((c) => c.isTerminal)) {
        return const TranscriptAssembler()
            .assemble(all.map((c) => c.asTranscript).toList());
      }

      final ready = _claimable(all);
      if (ready.isEmpty) {
        // Everything outstanding is waiting on backoff. Sleep until the soonest is due
        // rather than spinning.
        final wait = _timeUntilNextAttempt(all);
        if (wait == null) {
          // No claimable work and nothing scheduled: the store contains a chunk stuck in
          // `uploading` from a process that died. Reclaim it rather than hanging.
          await _reclaimStranded(all);
          continue;
        }
        _events.add(QueueWaiting(wait));
        await Future<void>.delayed(wait);
        continue;
      }

      await Future.wait(ready.map(_process));
    }
  }

  /// Chunks that may be started right now, lowest index first.
  List<ChunkRecord> _claimable(List<ChunkRecord> all) {
    final now = _now();
    final inFlight = all.where((c) => c.state == ChunkState.uploading).length;
    final slots = maxConcurrent - inFlight;
    if (slots <= 0) return const [];

    final ready = all
        .where((c) =>
            c.state == ChunkState.pending ||
            (c.state == ChunkState.backoff &&
                (c.nextAttemptAt == null || !c.nextAttemptAt!.isAfter(now))))
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    return ready.take(slots).toList();
  }

  Duration? _timeUntilNextAttempt(List<ChunkRecord> all) {
    final due = all
        .where((c) => c.state == ChunkState.backoff && c.nextAttemptAt != null)
        .map((c) => c.nextAttemptAt!)
        .toList()
      ..sort();
    if (due.isEmpty) return null;
    final wait = due.first.difference(_now());
    return wait.isNegative ? Duration.zero : wait;
  }

  /// A chunk left in `uploading` belongs to a process that no longer exists — the app was
  /// killed mid-request. Its upload may or may not have reached the provider, but we have
  /// no result either way, so it goes back in the queue.
  Future<void> _reclaimStranded(List<ChunkRecord> all) async {
    for (final chunk in all.where((c) => c.state == ChunkState.uploading)) {
      await store.update(chunk.copyWith(
        state: ChunkState.pending,
        nextAttemptAt: null,
      ));
      _events.add(QueueReclaimed(chunk.index));
    }
  }

  Future<void> _process(ChunkRecord chunk) async {
    final attempt = chunk.attempts + 1;
    await store.update(chunk.copyWith(
      state: ChunkState.uploading,
      attempts: attempt,
      nextAttemptAt: null,
    ));
    _events.add(QueueStarted(chunk.index, attempt));

    try {
      final bytes = await audio.read(chunk.plan);
      final segments = await transcription.transcribe(TranscribeRequest(
        audio: bytes,
        mimeType: audio.mimeType,
        offsetMs: chunk.startMs,
        languageHint: languageHint,
        primingPrompt: await _primingFor(chunk),
      ));

      await store.update(chunk.copyWith(
        state: ChunkState.transcribed,
        attempts: attempt,
        segments: segments,
        error: null,
      ));
      _events.add(QueueSucceeded(chunk.index));
    } catch (e) {
      final retryable = policy.isRetryable(e) && attempt < policy.maxAttempts;
      if (!retryable) {
        await store.update(chunk.copyWith(
          state: ChunkState.failed,
          attempts: attempt,
          error: e.toString(),
        ));
        _events.add(QueueGaveUp(chunk.index, e.toString()));
        return;
      }

      final delay = policy.backoffFor(
        attempt,
        retryAfter: e is ProviderException ? e.retryAfter : null,
        random: _random,
      );
      await store.update(chunk.copyWith(
        state: ChunkState.backoff,
        attempts: attempt,
        nextAttemptAt: _now().add(delay),
        error: e.toString(),
      ));
      _events.add(QueueRetrying(chunk.index, attempt, delay));
    }
  }

  /// The tail of the previous chunk, so proper nouns stay spelled consistently across the
  /// seam. Read from the store, not from memory, so priming survives a restart too.
  Future<String?> _primingFor(ChunkRecord chunk) async {
    if (chunk.index == 0) return null;
    final all = await store.forRecording(chunk.recordingId);
    for (final candidate in all) {
      if (candidate.index == chunk.index - 1 &&
          candidate.state == ChunkState.transcribed) {
        return Transcript(candidate.segments).primingTail();
      }
    }
    return null;
  }

  Future<void> dispose() => _events.close();
}

sealed class QueueEvent {
  const QueueEvent();
}

class QueueStarted extends QueueEvent {
  const QueueStarted(this.index, this.attempt);
  final int index;
  final int attempt;
}

class QueueSucceeded extends QueueEvent {
  const QueueSucceeded(this.index);
  final int index;
}

class QueueRetrying extends QueueEvent {
  const QueueRetrying(this.index, this.attempt, this.delay);
  final int index;
  final int attempt;
  final Duration delay;
}

class QueueGaveUp extends QueueEvent {
  const QueueGaveUp(this.index, this.reason);
  final int index;
  final String reason;
}

class QueueWaiting extends QueueEvent {
  const QueueWaiting(this.delay);
  final Duration delay;
}

class QueueReclaimed extends QueueEvent {
  const QueueReclaimed(this.index);
  final int index;
}
