import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/data/chunk_store.dart';
import 'package:transcript_app/src/data/database.dart';
import 'package:transcript_core/transcript_core.dart' as core;

void main() {
  late TranscriptDatabase db;
  late DriftChunkStore store;

  setUp(() async {
    db = TranscriptDatabase.forTesting(NativeDatabase.memory());
    store = DriftChunkStore(db);
    // Chunks are foreign-keyed to a recording, and that constraint is now enforced —
    // an orphan chunk would resume forever against a recording that does not exist.
    for (final id in ['r1', 'r2']) {
      await db.into(db.recordings).insert(
            RecordingsCompanion.insert(id: id, startedAt: DateTime.now()),
          );
    }
  });

  tearDown(() => db.close());

  core.ChunkRecord chunk(int index, {core.ChunkState? state}) => core.ChunkRecord(
        id: 'r1_c$index',
        recordingId: 'r1',
        index: index,
        startMs: index == 0 ? 0 : index * 45000 - 3000,
        contentStartMs: index * 45000,
        endMs: (index + 1) * 45000,
        state: state ?? core.ChunkState.pending,
      );

  test('a chunk round-trips through the database unchanged', () async {
    await store.putAll([chunk(0), chunk(1)]);

    final read = await store.forRecording('r1');
    expect(read, hasLength(2));
    expect(read.first.id, 'r1_c0');
    expect(read.first.contentStartMs, 0);
    expect(read[1].startMs, 42000, reason: 'the overlap offset must survive');
    expect(read.every((c) => c.state == core.ChunkState.pending), isTrue);
  });

  test('segments survive being written out and read back', () async {
    await store.putAll([chunk(0)]);
    await store.update(chunk(0).copyWith(
      state: core.ChunkState.transcribed,
      segments: const [
        core.TranscriptSegment(
            startMs: 0, endMs: 5000, text: 'Morning.', speaker: 'SPEAKER_01'),
        core.TranscriptSegment(startMs: 5000, endMs: 9000, text: 'Lets begin.'),
      ],
    ));

    final read = (await store.forRecording('r1')).single;
    expect(read.state, core.ChunkState.transcribed);
    expect(read.segments, hasLength(2));
    expect(read.segments.first.speaker, 'SPEAKER_01');
    expect(read.segments.last.text, 'Lets begin.');
  });

  test('retry bookkeeping survives a restart', () async {
    final due = DateTime.now().add(const Duration(seconds: 30));
    await store.putAll([chunk(0)]);
    await store.update(chunk(0).copyWith(
      state: core.ChunkState.backoff,
      attempts: 3,
      nextAttemptAt: due,
      error: '503 service unavailable',
    ));

    final read = (await store.forRecording('r1')).single;
    expect(read.attempts, 3);
    expect(read.nextAttemptAt!.difference(due).inSeconds.abs(), lessThan(2));
    expect(read.error, contains('503'));
  });

  test('chunks come back in index order regardless of write order', () async {
    await store.putAll([chunk(2), chunk(0), chunk(1)]);
    expect((await store.forRecording('r1')).map((c) => c.index), [0, 1, 2]);
  });

  test('recordings are isolated from one another', () async {
    await store.putAll([chunk(0)]);
    await store.putAll([
      core.ChunkRecord(
        id: 'r2_c0',
        recordingId: 'r2',
        index: 0,
        startMs: 0,
        contentStartMs: 0,
        endMs: 1000,
      ),
    ]);

    expect(await store.forRecording('r1'), hasLength(1));
    expect((await store.forRecording('r2')).single.id, 'r2_c0');
  });

  test('the launch query finds recordings with work still outstanding', () async {
    await store.putAll([chunk(0), chunk(1), chunk(2)]);
    await store.update(chunk(0).copyWith(state: core.ChunkState.transcribed));
    await store.update(chunk(1).copyWith(state: core.ChunkState.failed));

    // Chunk 2 is still pending, so this recording resumes.
    expect(await db.recordingsWithUnfinishedChunks(), ['r1']);

    await store.update(chunk(2).copyWith(state: core.ChunkState.transcribed));
    expect(await db.recordingsWithUnfinishedChunks(), isEmpty,
        reason: 'a fully terminal recording is finished, gaps included');
  });

  test('putAll is idempotent, so re-enqueueing a plan is safe', () async {
    await store.putAll([chunk(0)]);
    await store.update(chunk(0).copyWith(state: core.ChunkState.transcribed));
    await store.putAll([chunk(0).copyWith(state: core.ChunkState.pending)]);

    // The queue guards against this itself, but the store must not multiply rows.
    expect(await store.forRecording('r1'), hasLength(1));
  });

  test('the whole queue drains against a real database', () async {
    // The seam that matters: core's queue driving actual SQLite, not a fake map.
    final queue = core.ChunkQueue(
      store: store,
      transcription: _StubTranscription(),
      audio: _StubAudio(),
      policy: const core.RetryPolicy(base: Duration(milliseconds: 1)),
    );

    await queue.enqueue('r1', [chunk(0).plan, chunk(1).plan]);
    final transcript = await queue.drain('r1');

    expect(transcript.segments, hasLength(2));
    expect(transcript.gaps, isEmpty);

    final rows = await store.forRecording('r1');
    expect(rows.every((c) => c.state == core.ChunkState.transcribed), isTrue);
  });

  test('a chunk for a recording that does not exist is refused', () async {
    await expectLater(
      store.putAll([
        core.ChunkRecord(
          id: 'ghost_c0',
          recordingId: 'no_such_recording',
          index: 0,
          startMs: 0,
          contentStartMs: 0,
          endMs: 1000,
        ),
      ]),
      throwsA(anything),
      reason: 'without the foreign key enforced, orphan rows resume forever',
    );
  });

  test('deleting a recording takes its chunks with it', () async {
    await store.putAll([chunk(0), chunk(1)]);

    await (db.delete(db.recordings)..where((r) => r.id.equals('r1'))).go();

    expect(await store.forRecording('r1'), isEmpty,
        reason: 'orphaned chunk rows would resume forever against nothing');
  });
}

class _StubTranscription extends core.TranscriptionProvider {
  @override
  core.ProviderId get id => const core.ProviderId('stub');
  @override
  String get displayName => 'Stub';
  @override
  core.ProviderCapabilities get capabilities => const core.ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
      );
  @override
  Future<core.ConnectionResult> test() async =>
      core.ConnectionResult.success(summary: 'ok');

  @override
  Future<List<core.TranscriptSegment>> transcribe(
          core.TranscribeRequest request) async =>
      [
        core.TranscriptSegment(
          startMs: request.offsetMs,
          endMs: request.offsetMs + 45000,
          text: _speech[request.offsetMs] ?? 'unattributed speech',
        ),
      ];
}

/// Distinct speech per chunk. Near-identical text across a seam is what a duplicated
/// overlap looks like, and the assembler is right to remove it.
const _speech = {
  0: 'okay lets start with the auth migration this morning',
  42000: 'priya will own the rollout and qa signs off first',
};

class _StubAudio implements core.ChunkAudioReader {
  @override
  String get mimeType => 'audio/wav';
  @override
  Future<List<int>> read(core.PlannedChunk chunk) async => List.filled(8, 0);
}