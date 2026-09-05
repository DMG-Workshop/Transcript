import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  const assembler = TranscriptAssembler();

  TranscriptSegment seg(int start, int end, String text) =>
      TranscriptSegment(startMs: start, endMs: end, text: text);

  group('overlap dedup', () {
    test('drops a segment that lies entirely inside the previous chunk', () {
      final transcript = assembler.assemble([
        ChunkTranscript(
          index: 0,
          startMs: 0,
          contentStartMs: 0,
          endMs: 45000,
          segments: [seg(0, 42000, 'first chunk content')],
        ),
        ChunkTranscript(
          index: 1,
          startMs: 42000, // 3s overlap
          contentStartMs: 45000,
          endMs: 90000,
          segments: [
            seg(42000, 44500, 'first chunk content'), // repeated overlap
            seg(45000, 60000, 'second chunk content'),
          ],
        ),
      ]);

      expect(transcript.segments.map((s) => s.text),
          ['first chunk content', 'second chunk content']);
    });

    test('keeps a boundary-straddling segment whose words are genuinely new',
        () {
      final transcript = assembler.assemble([
        ChunkTranscript(
          index: 0,
          startMs: 0,
          contentStartMs: 0,
          endMs: 45000,
          segments: [seg(0, 40000, 'we should ship the migration')],
        ),
        ChunkTranscript(
          index: 1,
          startMs: 42000,
          contentStartMs: 45000,
          endMs: 90000,
          segments: [
            // Starts before the boundary but says something different — losing this
            // would drop real speech, which is the failure overlap exists to prevent.
            seg(43000, 47000, 'and then update the runbook'),
          ],
        ),
      ]);

      expect(transcript.segments, hasLength(2));
      expect(transcript.segments.last.text, 'and then update the runbook');
    });

    test('ignores punctuation and casing differences between the two chunks',
        () {
      final transcript = assembler.assemble([
        ChunkTranscript(
          index: 0,
          startMs: 0,
          contentStartMs: 0,
          endMs: 45000,
          segments: [seg(0, 42000, 'Okay, so the auth migration.')],
        ),
        ChunkTranscript(
          index: 1,
          startMs: 42000,
          contentStartMs: 45000,
          endMs: 90000,
          segments: [seg(42500, 44800, 'okay so the auth migration')],
        ),
      ]);

      expect(transcript.segments, hasLength(1),
          reason:
              'the two chunks were transcribed independently and will not agree '
              'on punctuation');
    });
  });

  group('failure isolation', () {
    test('a failed chunk becomes a gap, not a failed recording', () {
      final transcript = assembler.assemble([
        ChunkTranscript(
          index: 0,
          startMs: 0,
          contentStartMs: 0,
          endMs: 45000,
          segments: [seg(0, 44000, 'before the failure')],
        ),
        const ChunkTranscript(
          index: 1,
          startMs: 45000,
          contentStartMs: 45000,
          endMs: 90000,
          failed: true,
          error: 'upload failed after 4 attempts',
        ),
        ChunkTranscript(
          index: 2,
          startMs: 90000,
          contentStartMs: 90000,
          endMs: 130000,
          segments: [seg(90000, 128000, 'after the failure')],
        ),
      ]);

      expect(transcript.segments, hasLength(2));
      expect(transcript.gaps, hasLength(1));
      expect(transcript.toPromptFormat(), contains('[unintelligible'));
      expect(transcript.toPromptFormat(), contains('01:30'));
    });
  });

  test('chunks are ordered by index regardless of completion order', () {
    final transcript = assembler.assemble([
      ChunkTranscript(
        index: 2,
        startMs: 90000,
        contentStartMs: 90000,
        endMs: 130000,
        segments: [seg(90000, 128000, 'third')],
      ),
      ChunkTranscript(
        index: 0,
        startMs: 0,
        contentStartMs: 0,
        endMs: 45000,
        segments: [seg(0, 44000, 'first')],
      ),
      ChunkTranscript(
        index: 1,
        startMs: 45000,
        contentStartMs: 45000,
        endMs: 90000,
        segments: [seg(45000, 88000, 'second')],
      ),
    ]);

    expect(
        transcript.segments.map((s) => s.text), ['first', 'second', 'third']);
  });

  group('prompt format', () {
    test('carries timestamps the model can cite', () {
      const transcript = Transcript([
        TranscriptSegment(
            startMs: 72000, endMs: 80000, text: 'Ship it Thursday.'),
      ]);
      expect(transcript.toPromptFormat(), '[01:12] Ship it Thursday.');
    });

    test('includes speaker labels when diarization supplied them', () {
      const transcript = Transcript([
        TranscriptSegment(
            startMs: 0, endMs: 4000, text: 'Morning.', speaker: 'SPEAKER_01'),
      ]);
      expect(transcript.toPromptFormat(), contains('SPEAKER_01: Morning.'));
    });

    test('uses hours only once the recording is long enough to need them', () {
      const transcript = Transcript([
        TranscriptSegment(
            startMs: 3725000, endMs: 3730000, text: 'Still going.'),
      ]);
      expect(transcript.toPromptFormat(), startsWith('[1:02:05]'));
    });
  });

  test('primingTail returns whole words from the end', () {
    const transcript = Transcript([
      TranscriptSegment(
          startMs: 0,
          endMs: 1000,
          text: 'the quick brown fox jumps over the lazy dog repeatedly'),
    ]);
    final tail = transcript.primingTail(20);
    expect(tail.length, lessThanOrEqualTo(20));
    expect(tail, isNot(startsWith(' ')));
    expect(transcript.plainText, endsWith(tail));
  });

  test('token estimate is conservative rather than optimistic', () {
    final transcript = Transcript([
      TranscriptSegment(startMs: 0, endMs: 1000, text: 'word ' * 1000),
    ]);
    // 5000 chars / 3.5 — over-estimating costs an unnecessary map/reduce; under-
    // estimating silently truncates the transcript, which is far worse.
    expect(transcript.estimatedTokens, greaterThan(1000));
  });
}
