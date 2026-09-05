import '../providers/provider.dart';
import 'transcript.dart';

/// One window of a long transcript, to be extracted on its own.
class TranscriptWindow {
  const TranscriptWindow({
    required this.index,
    required this.total,
    required this.segments,
  });

  final int index;
  final int total;
  final List<TranscriptSegment> segments;

  int get startMs => segments.isEmpty ? 0 : segments.first.startMs;
  int get endMs => segments.isEmpty ? 0 : segments.last.endMs;

  Transcript get transcript => Transcript(segments);

  int get estimatedTokens => transcript.estimatedTokens;
}

/// Splits a transcript too long for one pass into windows.
///
/// Splits on speaker turns, never on a token count alone: cutting mid-discussion produces
/// half-formed action items on both sides of the seam, and the merge pass cannot put them
/// back together because neither half is a complete thought.
class SectionPlanner {
  const SectionPlanner({this.preferBreakWithin = 0.25});

  /// How far back from the budget the planner will look for a speaker change, as a
  /// fraction of the window. Beyond this the gain in coherence is not worth the extra
  /// windows a short cut would produce.
  final double preferBreakWithin;

  List<TranscriptWindow> split(Transcript transcript,
      {required int budgetTokens}) {
    final segments = transcript.segments;
    if (segments.isEmpty) return const [];
    if (budgetTokens <= 0) {
      throw ArgumentError.value(
          budgetTokens, 'budgetTokens', 'must be positive');
    }

    final windows = <List<TranscriptSegment>>[];
    var current = <TranscriptSegment>[];
    var currentTokens = 0;

    for (final segment in segments) {
      final tokens = _tokensOf(segment);

      // A single segment larger than the budget cannot be split further without
      // cutting mid-sentence, so it gets a window of its own and is allowed to exceed.
      if (current.isEmpty) {
        current.add(segment);
        currentTokens = tokens;
        continue;
      }

      if (currentTokens + tokens <= budgetTokens) {
        current.add(segment);
        currentTokens += tokens;
        continue;
      }

      final cut = _bestBreak(current);
      windows.add(current.sublist(0, cut));

      // Whatever came after the chosen break starts the next window, so a speaker's
      // turn is not split across two extractions.
      current = [...current.sublist(cut), segment];
      currentTokens = current.fold(0, (sum, s) => sum + _tokensOf(s));
    }

    if (current.isNotEmpty) windows.add(current);

    return [
      for (var i = 0; i < windows.length; i++)
        TranscriptWindow(
            index: i + 1, total: windows.length, segments: windows[i]),
    ];
  }

  /// The last speaker change within the tail of the window, or the end if there is none.
  int _bestBreak(List<TranscriptSegment> window) {
    if (window.length < 2) return window.length;

    final earliest = (window.length * (1 - preferBreakWithin)).floor();
    for (var i = window.length - 1; i > earliest && i > 0; i--) {
      final previous = window[i - 1].speaker;
      final here = window[i].speaker;
      if (here != null && previous != null && here != previous) return i;
    }
    return window.length;
  }

  static int _tokensOf(TranscriptSegment segment) =>
      (segment.text.length / 3.5).ceil() + 8; // + timestamp and speaker prefix
}
