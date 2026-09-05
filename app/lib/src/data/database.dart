import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// Recordings, and the chunk queue that makes them survive reality.
///
/// The chunk table is the durability story in full: the OS kills the app, the network
/// drops, the battery dies mid-meeting, and on relaunch the pipeline resumes from these
/// rows and re-uploads only what did not finish. Chunks are rows, never objects in memory.
@DataClassName('Recording')
class Recordings extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  DateTimeColumn get startedAt => dateTime()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();

  /// Path to the compressed copy kept for playback. The working PCM is deleted once
  /// every chunk reaches a terminal state.
  TextColumn get audioPath => text().nullable()();

  TextColumn get transcriptionProviderId => text().nullable()();
  TextColumn get structuringProviderId => text().nullable()();

  /// The note document as returned, so a schema change never orphans an old note.
  TextColumn get noteJson => text().nullable()();
  TextColumn get noteSchemaVersion => text().nullable()();
  TextColumn get promptVersion => text().nullable()();

  IntColumn get inputTokens => integer().nullable()();
  IntColumn get outputTokens => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One unit of work in the transcription queue.
class Chunks extends Table {
  TextColumn get id => text()();
  TextColumn get recordingId =>
      text().references(Recordings, #id, onDelete: KeyAction.cascade)();

  /// Position in the recording. Reassembly is ordered by this, never by completion.
  IntColumn get index => integer()();

  IntColumn get startMs => integer()();

  /// Where this chunk's new content begins; everything before it repeats the previous
  /// chunk's tail and is de-duplicated on reassembly.
  IntColumn get contentStartMs => integer()();
  IntColumn get endMs => integer()();

  TextColumn get path => text()();
  IntColumn get bytes => integer()();

  TextColumn get state => textEnum<ChunkState>()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();

  TextColumn get text => text().nullable()();

  /// Segment timings as JSON, so absolute offsets survive a restart.
  TextColumn get segmentsJson => text().nullable()();

  TextColumn get error => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

enum ChunkState {
  pending,
  uploading,

  /// Retryable failure: waiting on backoff. `nextAttemptAt` says when.
  backoff,

  transcribed,

  /// Terminal. Becomes a marked gap in the transcript rather than a failed recording.
  failed,
}

@DriftDatabase(tables: [Recordings, Chunks])
class TranscriptDatabase extends _$TranscriptDatabase {
  TranscriptDatabase() : super(_open());

  TranscriptDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  /// Work the queue can pick up right now, oldest first, bounded by the caller so no
  /// more than two or three uploads are ever in flight.
  Future<List<Chunk>> claimable(String recordingId, {int limit = 3}) {
    final now = DateTime.now();
    return (select(chunks)
          ..where((c) => c.recordingId.equals(recordingId))
          ..where((c) =>
              c.state.equalsValue(ChunkState.pending) |
              (c.state.equalsValue(ChunkState.backoff) &
                  c.nextAttemptAt.isSmallerOrEqualValue(now)))
          ..orderBy([(c) => OrderingTerm(expression: c.index)])
          ..limit(limit))
        .get();
  }

  /// Exponential backoff with jitter. A 429 should honour `Retry-After` instead — the
  /// caller passes that through as [override].
  Future<void> markForRetry(String chunkId, int attempts, {Duration? override}) {
    final delay = override ??
        Duration(seconds: (1 << attempts.clamp(0, 6)) + (chunkId.hashCode % 5).abs());
    return (update(chunks)..where((c) => c.id.equals(chunkId))).write(
      ChunksCompanion(
        state: const Value(ChunkState.backoff),
        attempts: Value(attempts),
        nextAttemptAt: Value(DateTime.now().add(delay)),
      ),
    );
  }

  Future<bool> isComplete(String recordingId) async {
    final pending = await (select(chunks)
          ..where((c) => c.recordingId.equals(recordingId))
          ..where((c) => c.state.equalsValue(ChunkState.transcribed).not() &
              c.state.equalsValue(ChunkState.failed).not()))
        .get();
    return pending.isEmpty;
  }
}

LazyDatabase _open() => LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      return NativeDatabase.createInBackground(
        File(p.join(dir.path, 'transcript.sqlite')),
      );
    });
