/// Strips secrets and personal content out of text that is about to be written
/// somewhere durable — a crash report, a diagnostic log, a support bundle.
///
/// The app's whole promise is that recordings and keys stay where the user put them.
/// A crash handler is the classic way that promise breaks: an exception message quotes
/// the request that failed, the request carried an `Authorization` header, and the key
/// lands in a log file the user later mails to someone. Redaction is the last line of
/// defence for text that has already escaped the code paths that knew what it was.
///
/// Two mechanisms, deliberately layered:
///
/// * **Known secrets** — the literal key strings the app is holding right now, scrubbed
///   by exact match. This is the strong guarantee: it does not care what shape a
///   provider's keys are, only that this exact string must never appear.
/// * **Shapes** — patterns for keys we have never been handed (one typed into a field
///   but not yet saved, a provider added after this code shipped). Weaker, but it is
///   what catches the case nobody anticipated.
///
/// Neither is trusted alone, and both run on every string.
library;

/// What a redaction removed. Left in the output in place of the secret, because a
/// report with a visible `[redacted: api key]` reads as deliberate, whereas silently
/// deleted text reads as a truncation bug and sends people hunting for the wrong thing.
enum RedactionKind {
  apiKey('api key'),
  authorizationHeader('authorization header'),
  queryParameter('url secret'),
  homeDirectory('home directory'),
  emailAddress('email address');

  const RedactionKind(this.label);
  final String label;

  String get placeholder => '[redacted: $label]';
}

/// Scrubs secrets out of arbitrary text.
///
/// Cheap to construct and safe to keep for the life of the process; [remember] and
/// [forget] track which keys are live as the user adds and removes them.
class Redactor {
  Redactor({Iterable<String> secrets = const []}) {
    for (final secret in secrets) {
      remember(secret);
    }
  }

  /// Below this length an "exact match" is not a match, it is a coincidence. A four
  /// character key would scrub those four characters everywhere they appeared —
  /// including inside ordinary words — and produce a report nobody can read.
  static const int minimumSecretLength = 8;

  final Set<String> _secrets = {};

  /// Registers a literal secret to scrub on sight. Values shorter than
  /// [minimumSecretLength] are ignored rather than accepted and misapplied.
  void remember(String? secret) {
    if (secret == null) return;
    final trimmed = secret.trim();
    if (trimmed.length < minimumSecretLength) return;
    _secrets.add(trimmed);
  }

  void forget(String secret) => _secrets.remove(secret.trim());

  void forgetAll() => _secrets.clear();

  /// How many literal secrets are currently registered. Exposed so a diagnostics screen
  /// can say "3 keys are being scrubbed" without ever showing one.
  int get secretCount => _secrets.length;

  /// Returns [input] with every secret this redactor can recognise replaced by a
  /// labelled placeholder.
  String scrub(String input) {
    if (input.isEmpty) return input;

    var out = input;

    // Longest first: if one registered secret is a substring of another, replacing the
    // short one first would leave the remaining fragment of the long one in the text.
    final ordered = _secrets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in ordered) {
      out = out.replaceAll(secret, RedactionKind.apiKey.placeholder);
    }

    for (final rule in _shapeRules) {
      out = out.replaceAllMapped(rule.pattern, (match) {
        // A rule that captures a prefix keeps it, so the reader can still tell which
        // header or parameter was involved — only the value is destroyed.
        final prefix = rule.keepsPrefix ? match.group(1) ?? '' : '';
        return '$prefix${rule.kind.placeholder}';
      });
    }

    return out;
  }

  /// Convenience for the common case of an exception plus its stack.
  String scrubError(Object error, [StackTrace? stack]) {
    final buffer = StringBuffer(scrub(error.toString()));
    if (stack != null) {
      buffer
        ..write('\n')
        ..write(scrub(stack.toString()));
    }
    return buffer.toString();
  }

  static final List<_ShapeRule> _shapeRules = [
    // OpenAI and Anthropic: `sk-...`, `sk-ant-...`, `sk-proj-...`. The trailing run is
    // deliberately generous — these keys have grown longer with every generation.
    _ShapeRule(
      RegExp(r'\bsk-[A-Za-z0-9_\-]{16,}'),
      RedactionKind.apiKey,
    ),
    // Google AI Studio / Gemini.
    _ShapeRule(
      RegExp(r'\bAIza[A-Za-z0-9_\-]{20,}'),
      RedactionKind.apiKey,
    ),
    // Hugging Face, used for model downloads.
    _ShapeRule(
      RegExp(r'\bhf_[A-Za-z0-9]{16,}'),
      RedactionKind.apiKey,
    ),
    // `Authorization: Bearer xyz` and the header names the adapters actually send.
    // Matching the header name rather than the value means an unrecognised key format
    // is still caught the moment it appears in a header.
    _ShapeRule(
      RegExp(
        r'((?:authorization|x-api-key|x-goog-api-key)\s*[:=]\s*)(?:bearer\s+)?[^\s,;"}\]]+',
        caseSensitive: false,
      ),
      RedactionKind.authorizationHeader,
      keepsPrefix: true,
    ),
    // Keys passed in a URL, which is how Gemini authenticates. These end up in
    // exception messages verbatim.
    _ShapeRule(
      RegExp(
        r'([?&](?:key|api_key|apikey|access_token|token)=)[^\s&"]+',
        caseSensitive: false,
      ),
      RedactionKind.queryParameter,
      keepsPrefix: true,
    ),
    // Absolute paths carry the device owner's name on desktop and in simulator runs.
    // The rest of the path is kept: which directory failed is the useful part.
    _ShapeRule(
      RegExp(r'(?:/Users/|/home/)[^/\s:"]+'),
      RedactionKind.homeDirectory,
    ),
    _ShapeRule(
      RegExp(r'[A-Za-z]:\\Users\\[^\\\s:"]+', caseSensitive: false),
      RedactionKind.homeDirectory,
    ),
    // An address typed into a local-server field, or one that appears in an error from
    // a provider account. Not a secret, but it identifies a person.
    _ShapeRule(
      RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b'),
      RedactionKind.emailAddress,
    ),
  ];
}

class _ShapeRule {
  _ShapeRule(this.pattern, this.kind, {this.keepsPrefix = false});

  final RegExp pattern;
  final RedactionKind kind;

  /// Whether group 1 of the pattern is a prefix to preserve in the output.
  final bool keepsPrefix;
}
