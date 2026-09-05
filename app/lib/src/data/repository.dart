import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:transcript_core/transcript_core.dart';

import 'database.dart';

/// Persistence for recordings and their notes.
///
/// The transcript is stored the moment it exists, before structuring is attempted, so a
/// model failure never costs the user their recording. The note is stored as the raw JSON
/// the provider returned alongside the schema and prompt versions that produced it, so an
/// old note stays readable after either changes.
class RecordingRepository {
  const RecordingRepository(this._db);

  final TranscriptDatabase _db;

  Future<String> createRecording({
    required String path,
    required Duration duration,
    required String transcriptionProviderId,
    required String structuringProviderId,
  }) async {
    final id = 'r_${DateTime.now().microsecondsSinceEpoch}';
    await _db.into(_db.recordings).insert(RecordingsCompanion.insert(
          id: id,
          startedAt: DateTime.now(),
          audioPath: Value(path),
          durationMs: Value(duration.inMilliseconds),
          transcriptionProviderId: Value(transcriptionProviderId),
          structuringProviderId: Value(structuringProviderId),
        ));
    return id;
  }

  /// Saves the transcript on its own. Called before structuring is attempted.
  Future<void> saveTranscript(String recordingId, Transcript transcript) =>
      (_db.update(_db.recordings)..where((r) => r.id.equals(recordingId))).write(
        RecordingsCompanion(
          title: Value(_provisionalTitle(transcript)),
          noteJson: const Value.absent(),
        ),
      );

  Future<void> saveNote(String recordingId, StructureOutcome outcome) =>
      (_db.update(_db.recordings)..where((r) => r.id.equals(recordingId))).write(
        RecordingsCompanion(
          title: Value(outcome.document.meta.title),
          noteJson: Value(jsonEncode(outcome.raw)),
          structuringModel: Value(outcome.model),
          noteSchemaVersion: const Value(noteSchemaVersion),
          promptVersion: const Value(StructuringPrompts.promptVersion),
          inputTokens: Value(outcome.inputTokens),
          outputTokens: Value(outcome.outputTokens),
        ),
      );

  Future<List<Recording>> all() => (_db.select(_db.recordings)
        ..orderBy([(r) => OrderingTerm.desc(r.startedAt)]))
      .get();

  Stream<List<Recording>> watchAll() => (_db.select(_db.recordings)
        ..orderBy([(r) => OrderingTerm.desc(r.startedAt)]))
      .watch();

  Future<Recording?> byId(String id) =>
      (_db.select(_db.recordings)..where((r) => r.id.equals(id)))
          .getSingleOrNull();

  /// Deletes the row and the audio file together, so storage does not leak recordings
  /// the user believes they removed.
  Future<void> delete(String id) async {
    final recording = await byId(id);
    final path = recording?.audioPath;
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    }
    await (_db.delete(_db.recordings)..where((r) => r.id.equals(id))).go();
  }

  /// Until the model has named the recording, the first words of it will do.
  static String _provisionalTitle(Transcript transcript) {
    final text = transcript.plainText.trim();
    if (text.isEmpty) return 'Untitled recording';
    final words = text.split(RegExp(r'\s+')).take(6).join(' ');
    return words.length > 48 ? '${words.substring(0, 48)}…' : words;
  }
}

/// Decodes a stored note back into a document. Returns null for a recording whose
/// structuring failed or has not run — the transcript is still there either way.
NoteDocument? decodeNote(Recording recording) {
  final raw = recording.noteJson;
  if (raw == null) return null;
  final decoded = jsonDecode(raw);
  return decoded is Map<String, dynamic> ? NoteDocument.fromJson(decoded) : null;
}
