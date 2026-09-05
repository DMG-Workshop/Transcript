import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:transcript_core/transcript_core.dart' as core;

import 'database.dart';

/// SQLite-backed [core.ChunkStore].
///
/// Every state change the queue makes goes through here and lands on disk before the
/// queue moves on. That is the whole point: after this returns, the work is recoverable
/// even if the process is killed a millisecond later.
class DriftChunkStore implements core.ChunkStore {
  const DriftChunkStore(this._db);

  final TranscriptDatabase _db;

  @override
  Future<void> putAll(List<core.ChunkRecord> records) => _db.batch((batch) {
        batch.insertAll(
          _db.chunks,
          records.map(_toCompanion).toList(),
          mode: InsertMode.insertOrReplace,
        );
      });

  @override
  Future<void> update(core.ChunkRecord record) => _db
      .into(_db.chunks)
      .insertOnConflictUpdate(_toCompanion(record));

  @override
  Future<List<core.ChunkRecord>> forRecording(String recordingId) async {
    final rows = await (_db.select(_db.chunks)
          ..where((c) => c.recordingId.equals(recordingId))
          ..orderBy([(c) => OrderingTerm(expression: c.chunkIndex)]))
        .get();
    return rows.map(_fromRow).toList();
  }

  ChunksCompanion _toCompanion(core.ChunkRecord r) => ChunksCompanion.insert(
        id: r.id,
        recordingId: r.recordingId,
        chunkIndex: r.index,
        startMs: r.startMs,
        contentStartMs: r.contentStartMs,
        endMs: r.endMs,
        state: _stateToDb(r.state),
        attempts: Value(r.attempts),
        nextAttemptAt: Value(r.nextAttemptAt),
        segmentsJson: Value(
          r.segments.isEmpty ? null : jsonEncode(r.segments.map(_segmentToJson).toList()),
        ),
        transcriptText: Value(
          r.segments.isEmpty ? null : r.segments.map((s) => s.text).join(' '),
        ),
        error: Value(r.error),
      );

  static core.ChunkRecord _fromRow(Chunk row) => core.ChunkRecord(
        id: row.id,
        recordingId: row.recordingId,
        index: row.chunkIndex,
        startMs: row.startMs,
        contentStartMs: row.contentStartMs,
        endMs: row.endMs,
        state: _stateFromDb(row.state),
        attempts: row.attempts,
        nextAttemptAt: row.nextAttemptAt,
        segments: _segmentsFromJson(row.segmentsJson),
        error: row.error,
      );

  static Map<String, dynamic> _segmentToJson(core.TranscriptSegment s) => {
        'startMs': s.startMs,
        'endMs': s.endMs,
        'text': s.text,
        if (s.speaker != null) 'speaker': s.speaker,
      };

  static List<core.TranscriptSegment> _segmentsFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().map((j) {
      return core.TranscriptSegment(
        startMs: j['startMs'] as int? ?? 0,
        endMs: j['endMs'] as int? ?? 0,
        text: j['text'] as String? ?? '',
        speaker: j['speaker'] as String?,
      );
    }).toList();
  }

  // The core enum and the drift enum are deliberately separate types: core must not
  // depend on drift, and drift's textEnum is a storage detail. This is the seam.
  static ChunkState _stateToDb(core.ChunkState s) => switch (s) {
        core.ChunkState.pending => ChunkState.pending,
        core.ChunkState.uploading => ChunkState.uploading,
        core.ChunkState.backoff => ChunkState.backoff,
        core.ChunkState.transcribed => ChunkState.transcribed,
        core.ChunkState.failed => ChunkState.failed,
      };

  static core.ChunkState _stateFromDb(ChunkState s) => switch (s) {
        ChunkState.pending => core.ChunkState.pending,
        ChunkState.uploading => core.ChunkState.uploading,
        ChunkState.backoff => core.ChunkState.backoff,
        ChunkState.transcribed => core.ChunkState.transcribed,
        ChunkState.failed => core.ChunkState.failed,
      };
}
