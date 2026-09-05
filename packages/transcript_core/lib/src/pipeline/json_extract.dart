import 'dart:convert';

/// Pulls a JSON object out of a model response.
///
/// Providers with a native structured-output mode return clean JSON, and this is a
/// no-op for them. Everything else — local models especially — wraps the object in a
/// markdown fence, prefixes it with "Here is the JSON:", or appends a closing remark.
/// Tolerating that is cheaper than a repair round-trip.
Map<String, dynamic>? extractJsonObject(String raw) {
  final direct = _tryDecode(raw.trim());
  if (direct != null) return direct;

  final fenced = _stripFence(raw);
  if (fenced != null) {
    final decoded = _tryDecode(fenced);
    if (decoded != null) return decoded;
  }

  // Last resort: the outermost balanced {...}, ignoring braces inside strings.
  final span = _outermostObject(raw);
  if (span != null) return _tryDecode(span);

  return null;
}

Map<String, dynamic>? _tryDecode(String s) {
  if (s.isEmpty) return null;
  try {
    final decoded = jsonDecode(s);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String? _stripFence(String raw) {
  final match = RegExp(r'```(?:json)?\s*\n?([\s\S]*?)```', multiLine: true)
      .firstMatch(raw);
  return match?.group(1)?.trim();
}

String? _outermostObject(String raw) {
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;

  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }

    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      if (depth == 0) start = i;
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0 && start >= 0) return raw.substring(start, i + 1);
    }
  }
  return null;
}
