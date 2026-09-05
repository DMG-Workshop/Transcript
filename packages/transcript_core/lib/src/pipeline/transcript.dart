import '../providers/provider.dart';

/// An assembled transcript with absolute timestamps.
class Transcript {
  const Transcript(this.segments, {this.gaps = const []});

  final List<TranscriptSegment> segments;

  /// Spans that could not be transcribed. A failed chunk becomes a gap rather than a
  /// failed recording — the note is built from everything else and the user can retry
  /// just this span.
  final List<TranscriptGap> gaps;

  int get durationMs => segments.isEmpty ? 0 : segments.last.endMs;

  bool get isEmpty => segments.every((s) => s.text.trim().isEmpty);

  /// Plain text, for quote verification and token estimation.
  String get plainText => segments.map((s) => s.text).join(' ');

  /// The form sent to the model: timestamps prefixed so `sourceRef` offsets are
  /// something the model can actually produce, with gaps marked honestly so it does not
  /// invent continuity across them.
  String toPromptFormat() {
    final entries = <_Timed>[
      ...segments.map((s) => _Timed(s.startMs, _formatSegment(s))),
      ...gaps.map((g) => _Timed(
            g.startMs,
            '[${_timestamp(g.startMs)}–${_timestamp(g.endMs)}] '
            '[unintelligible — this span could not be transcribed]',
          )),
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));

    return entries.map((e) => e.line).join('\n');
  }

  static String _formatSegment(TranscriptSegment s) {
    final speaker = s.speaker == null ? '' : '${s.speaker}: ';
    return '[${_timestamp(s.startMs)}] $speaker${s.text.trim()}';
  }

  static String _timestamp(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// Rough token count. Deliberately conservative: over-estimating costs an unnecessary
  /// map/reduce, under-estimating costs a silently truncated transcript.
  int get estimatedTokens => (plainText.length / 3.5).ceil();

  /// The tail of the transcript, used to prime the next chunk so proper nouns stay
  /// spelled consistently across the seam.
  String primingTail([int maxChars = 200]) {
    final text = plainText.trimRight();
    if (text.length <= maxChars) return text;
    final tail = text.substring(text.length - maxChars);
    final space = tail.indexOf(' ');
    // >= 0, not > 0: when the cut lands exactly on a space, index 0 is still a
    // valid word boundary and dropping it is what keeps the prompt clean.
    return space >= 0 ? tail.substring(space + 1) : tail;
  }
}

class TranscriptGap {
  const TranscriptGap(this.startMs, this.endMs, this.reason);
  final int startMs;
  final int endMs;
  final String reason;
}

class _Timed {
  const _Timed(this.startMs, this.line);
  final int startMs;
  final String line;
}

/// Reassembles per-chunk transcripts into one transcript, removing the duplicated words
/// each overlap produces.
///
/// The overlap exists so no word is lost at a seam; this is the other half of that trade.
/// Without dedup, every seam repeats up to three seconds of speech, which reads badly and
/// gives the model duplicate action items to extract.
class TranscriptAssembler {
  const TranscriptAssembler();

  Transcript assemble(List<ChunkTranscript> chunks) {
    final ordered = [...chunks]..sort((a, b) => a.index.compareTo(b.index));

    final segments = <TranscriptSegment>[];
    final gaps = <TranscriptGap>[];

    for (final chunk in ordered) {
      if (chunk.failed) {
        gaps.add(TranscriptGap(
          chunk.contentStartMs,
          chunk.endMs,
          chunk.error ?? 'transcription failed',
        ));
        continue;
      }

      for (final segment in chunk.segments) {
        // Anything starting before this chunk's content boundary is overlap the previous
        // chunk already covered.
        if (segment.endMs <= chunk.contentStartMs) continue;

        if (segment.startMs < chunk.contentStartMs &&
            _isMostlyOverlap(segment, chunk.contentStartMs) &&
            _duplicatesTail(segments, segment)) {
          continue;
        }
        segments.add(segment);
      }
    }

    segments.sort((a, b) => a.startMs.compareTo(b.startMs));
    return Transcript(segments, gaps: gaps);
  }

  /// Whether a straddling segment is mostly repeat rather than mostly new.
  ///
  /// The overlap is a few seconds; a segment that merely *begins* inside it can carry a
  /// minute of new speech after the boundary. Discarding that as a duplicate would throw
  /// away most of a chunk, so only segments whose span lies mostly before the boundary
  /// are even considered for removal.
  static bool _isMostlyOverlap(TranscriptSegment segment, int contentStartMs) {
    final repeated = contentStartMs - segment.startMs;
    final fresh = segment.endMs - contentStartMs;
    return repeated >= fresh;
  }

  /// A segment straddling the boundary is a duplicate if it *opens* with the words the
  /// assembled transcript already *ends* with.
  ///
  /// Direction matters: an overlap repeats the end of the previous chunk at the start of
  /// this one, so comparing the candidate's opening against the tail's ending is the only
  /// alignment that means anything. Comparing whole segments would give a long segment —
  /// a provider returning one block for a 45-second chunk — a near-random score.
  ///
  /// Compared on normalized words, because the two chunks were transcribed independently
  /// and will not agree on punctuation or casing.
  static bool _duplicatesTail(
    List<TranscriptSegment> assembled,
    TranscriptSegment candidate,
  ) {
    if (assembled.isEmpty) return false;

    final candidateWords = _words(candidate.text);
    if (candidateWords.isEmpty) return true;

    // Roughly the last two segments: enough to cover a few seconds of overlap.
    final tail = assembled.length >= 2
        ? assembled.sublist(assembled.length - 2)
        : assembled;
    final tailWords = _words(tail.map((s) => s.text).join(' '));
    if (tailWords.isEmpty) return false;

    // Bounded: an overlap is seconds of speech, so comparing more than this many words
    // only dilutes the signal.
    const maxWindow = 40;

    /// Below this many words the comparison is thin evidence — three matches out of four
    /// is 75%, which clears a percentage threshold while meaning very little. Short
    /// windows must match outright.
    const strictBelow = 6;
    var window = candidateWords.length < tailWords.length
        ? candidateWords.length
        : tailWords.length;
    if (window > maxWindow) window = maxWindow;

    var matched = 0;
    for (var i = 0; i < window; i++) {
      final tailWord = tailWords[tailWords.length - window + i];
      if (candidateWords[i] == tailWord) {
        matched++;
      }
    }
    final required = window < strictBelow ? 1.0 : 0.7;
    return matched / window >= required;
  }

  static List<String> _words(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
}

/// One chunk's transcription result, as stored in the chunk queue.
class ChunkTranscript {
  const ChunkTranscript({
    required this.index,
    required this.startMs,
    required this.contentStartMs,
    required this.endMs,
    this.segments = const [],
    this.failed = false,
    this.error,
  });

  final int index;
  final int startMs;
  final int contentStartMs;
  final int endMs;
  final List<TranscriptSegment> segments;
  final bool failed;
  final String? error;
}
