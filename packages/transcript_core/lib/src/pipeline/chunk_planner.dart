/// Chunker constants and the boundary planner.
///
/// Chunking exists for three independent reasons: provider request ceilings, failure
/// isolation (one bad chunk must never cost the recording), and overlapping transcription
/// with recording so results arrive as the meeting runs.
class ChunkerConfig {
  const ChunkerConfig({
    this.targetDuration = const Duration(seconds: 45),
    this.minDuration = const Duration(seconds: 15),
    this.maxDuration = const Duration(minutes: 10),
    this.overlap = const Duration(seconds: 3),
    this.silenceThreshold = const Duration(milliseconds: 400),
    this.maxBytes = 20 * 1024 * 1024,
    this.sampleRate = 16000,
    this.bytesPerSample = 2,
  });

  /// Where a cut lands if speech pauses conveniently.
  final Duration targetDuration;

  /// Below this a chunk carries too little context to transcribe well; fast dialogue
  /// would otherwise be shredded into fragments.
  final Duration minDuration;

  /// Hard cut if nobody stops talking.
  final Duration maxDuration;

  /// Carried into the next chunk and de-duplicated on reassembly. Without it words are
  /// lost at every seam; without the dedup they are doubled.
  final Duration overlap;

  /// A pause at least this long is a safe place to cut.
  final Duration silenceThreshold;

  /// Ceiling from the provider's capabilities, with headroom.
  final int maxBytes;

  final int sampleRate;
  final int bytesPerSample;

  /// 16 kHz mono PCM16 — 32 kB per second, which is what every engine resamples to anyway.
  int get bytesPerSecond => sampleRate * bytesPerSample;

  /// The byte ceiling expressed as a duration, so the planner can apply one rule.
  Duration get maxDurationForBytes =>
      Duration(milliseconds: (maxBytes / bytesPerSecond * 1000).floor());

  /// Effective maximum: whichever of the time and byte limits binds first.
  Duration get effectiveMaxDuration =>
      maxDuration < maxDurationForBytes ? maxDuration : maxDurationForBytes;

  ChunkerConfig forProvider(int providerMaxBytes) => ChunkerConfig(
        targetDuration: targetDuration,
        minDuration: minDuration,
        maxDuration: maxDuration,
        overlap: overlap,
        silenceThreshold: silenceThreshold,
        maxBytes: providerMaxBytes == 0
            ? maxBytes
            : (providerMaxBytes * 0.8)
                .floor(), // headroom for container + multipart
        sampleRate: sampleRate,
        bytesPerSample: bytesPerSample,
      );
}

/// A span of detected silence, from the recorder's VAD.
class SilenceWindow {
  const SilenceWindow(this.startMs, this.endMs);
  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;

  /// Cut in the middle of the pause, giving both sides breathing room.
  int get midpointMs => startMs + durationMs ~/ 2;
}

/// A planned chunk. `startMs`/`endMs` are the audio to send; `contentStartMs` is where
/// this chunk's *new* content begins, so the reassembler knows which part is overlap.
class PlannedChunk {
  const PlannedChunk({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.contentStartMs,
    required this.boundary,
  });

  final int index;
  final int startMs;
  final int endMs;

  /// Everything before this offset repeats the previous chunk's tail.
  final int contentStartMs;

  final ChunkBoundary boundary;

  int get durationMs => endMs - startMs;
  bool get hasOverlap => contentStartMs > startMs;
}

enum ChunkBoundary {
  /// Cut inside a detected pause — the good case.
  silence,

  /// Nobody stopped talking before the hard limit. The overlap and priming prompt are
  /// what keep the seam readable.
  forced,

  /// End of the recording.
  end,
}

/// Turns a recording plus its detected silences into a chunk plan.
///
/// Pure and synchronous, so the seam logic that decides whether words get dropped is
/// unit-testable without audio, a device, or a provider.
class ChunkPlanner {
  const ChunkPlanner([this.config = const ChunkerConfig()]);

  final ChunkerConfig config;

  List<PlannedChunk> plan({
    required int totalDurationMs,
    required List<SilenceWindow> silences,
  }) {
    if (totalDurationMs <= 0) return const [];

    final target = config.targetDuration.inMilliseconds;
    final min = config.minDuration.inMilliseconds;
    final max = config.effectiveMaxDuration.inMilliseconds;
    final overlap = config.overlap.inMilliseconds;
    final minSilence = config.silenceThreshold.inMilliseconds;

    final usable = silences.where((s) => s.durationMs >= minSilence).toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

    final chunks = <PlannedChunk>[];
    var contentStart = 0;
    var index = 0;

    while (contentStart < totalDurationMs) {
      final remaining = totalDurationMs - contentStart;

      // What is left fits comfortably in one chunk.
      if (remaining <= target) {
        chunks.add(_build(
            index, contentStart, totalDurationMs, overlap, ChunkBoundary.end));
        break;
      }

      final earliest = contentStart + min;
      // Never plan a cut past the end of the recording.
      final latest = _min(contentStart + max, totalDurationMs);
      final ideal = contentStart + target;

      final cut = _bestSilenceCut(usable, earliest, latest, ideal);
      var end = cut ?? latest;
      var boundary = cut == null ? ChunkBoundary.forced : ChunkBoundary.silence;

      // Absorb a tail too short to transcribe well rather than emitting it alone — a
      // three-second chunk carries no context and transcribes badly. Only when the
      // combined span still fits under the ceiling.
      if (totalDurationMs - end < min && remaining <= max) {
        end = totalDurationMs;
        boundary = ChunkBoundary.end;
      }

      chunks.add(_build(index, contentStart, end, overlap, boundary));
      if (boundary == ChunkBoundary.end) break;
      contentStart = end;
      index++;
    }

    return chunks;
  }

  PlannedChunk _build(
    int index,
    int contentStart,
    int end,
    int overlap,
    ChunkBoundary boundary,
  ) {
    // The first chunk has nothing to overlap with.
    final start = index == 0 ? contentStart : _max(0, contentStart - overlap);
    return PlannedChunk(
      index: index,
      startMs: start,
      endMs: end,
      contentStartMs: contentStart,
      boundary: boundary,
    );
  }

  /// The silence closest to the target, within the legal window.
  static int? _bestSilenceCut(
    List<SilenceWindow> silences,
    int earliest,
    int latest,
    int ideal,
  ) {
    int? best;
    var bestDistance = 1 << 62;

    for (final s in silences) {
      final mid = s.midpointMs;
      if (mid < earliest) continue;
      if (mid > latest) break; // sorted
      final distance = (mid - ideal).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = mid;
      }
    }
    return best;
  }

  static int _max(int a, int b) => a > b ? a : b;

  static int _min(int a, int b) => a < b ? a : b;
}
