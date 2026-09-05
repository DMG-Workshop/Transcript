/// Checks that every `sourceRef.quote` in a note actually appears in the transcript.
///
/// This is the cheapest anti-fabrication measure in the app and the only one that costs
/// nothing per run: deterministic, offline, no tokens. A model that invents a task must
/// also invent a quote, and an invented quote does not survive this check.
///
/// The match is deliberately lenient about the things speech-to-text and models both
/// vary on — case, punctuation, whitespace, smart quotes — and strict about words.
class QuoteVerifier {
  QuoteVerifier(String transcript) : _haystack = _normalize(transcript);

  final String _haystack;

  /// Fraction of the quote's words that must appear, in order, for it to count as found.
  /// Below 1.0 because models routinely drop a filler word when quoting.
  static const double threshold = 0.85;

  /// Quotes shorter than this are too generic to verify meaningfully — "we should" would
  /// match almost any transcript — so they are neither confirmed nor flagged.
  static const int minWords = 3;

  QuoteVerdict verify(String quote) {
    final needle = _normalize(quote);
    if (needle.isEmpty) return QuoteVerdict.missing;

    final words = needle.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length < minWords) return QuoteVerdict.tooShort;

    if (_haystack.contains(needle)) return QuoteVerdict.exact;

    // Ordered subsequence match, tolerant of a dropped or altered word.
    var cursor = 0;
    var matched = 0;
    for (final word in words) {
      final at = _haystack.indexOf(word, cursor);
      if (at >= 0) {
        matched++;
        cursor = at + word.length;
      }
    }
    return matched / words.length >= threshold
        ? QuoteVerdict.approximate
        : QuoteVerdict.missing;
  }

  /// Lowercases, folds curly quotes and dashes, strips punctuation, collapses whitespace.
  static String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[‘’‛]'), "'")
      .replaceAll(RegExp(r'[“”]'), '"')
      .replaceAll(RegExp(r'[‐-―]'), '-')
      .replaceAll(RegExp(r'[^a-z0-9\s\x27-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

enum QuoteVerdict {
  /// Found character-for-character after normalization.
  exact,

  /// Found with minor word-level drift — acceptable.
  approximate,

  /// Not in the transcript. The item is shown to the user marked unverified.
  missing,

  /// Too short to be worth checking.
  tooShort;

  bool get isVerified => this == exact || this == approximate;

  /// Only outright misses are flagged. Flagging short quotes would train users to ignore
  /// the badge, which would defeat the point of having one.
  bool get shouldFlag => this == missing;
}
