/// A single schema violation, addressed by JSON Pointer.
class SchemaViolation {
  const SchemaViolation(this.pointer, this.message);

  /// RFC 6901 pointer to the offending value, e.g. `/tasks/2/dueDate`.
  final String pointer;
  final String message;

  /// The line as it appears in the repair prompt sent back to the model.
  @override
  String toString() => '${pointer.isEmpty ? '(root)' : pointer}: $message';
}

/// Validates parsed JSON against the subset of JSON Schema the canonical NoteDocument
/// schema actually uses: `type` (including nullable unions), `required`, `properties`,
/// `additionalProperties: false`, `items`, `enum`, and local `$ref` into `$defs`.
///
/// Deliberately not a general-purpose validator. A full implementation would be a
/// dependency and a maintenance surface; this covers what we author and fails loudly on
/// anything it does not recognise, so an unsupported keyword can never pass silently.
class SchemaValidator {
  SchemaValidator(this.schema)
      : _defs = (schema[r'$defs'] as Map?)?.cast<String, dynamic>() ?? const {};

  final Map<String, dynamic> schema;
  final Map<String, dynamic> _defs;

  /// Returns every violation found. An empty list means the document validates.
  List<SchemaViolation> validate(Object? value) {
    final out = <SchemaViolation>[];
    _check(value, schema, '', out);
    return out;
  }

  bool isValid(Object? value) => validate(value).isEmpty;

  void _check(
    Object? value,
    Map<String, dynamic> node,
    String pointer,
    List<SchemaViolation> out,
  ) {
    final ref = node[r'$ref'];
    if (ref is String) {
      const prefix = r'#/$defs/';
      final target =
          ref.startsWith(prefix) ? _defs[ref.substring(prefix.length)] : null;
      if (target is! Map) {
        out.add(SchemaViolation(pointer, 'unresolved schema reference "$ref"'));
        return;
      }
      _check(value, target.cast<String, dynamic>(), pointer, out);
      return;
    }

    final types = _typesOf(node);
    if (types.isNotEmpty && !types.any((t) => _matchesType(value, t))) {
      out.add(SchemaViolation(
        pointer,
        'expected ${types.join(' or ')}, got ${_describe(value)}',
      ));
      return; // further checks would only produce noise
    }

    final allowed = node['enum'];
    if (allowed is List && !allowed.contains(value)) {
      out.add(SchemaViolation(
        pointer,
        'expected one of ${allowed.map((e) => '"$e"').join(', ')}, got ${_describe(value)}',
      ));
    }

    if (value is Map) {
      final props =
          (node['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
      final required = (node['required'] as List?)?.cast<String>() ?? const [];

      for (final key in required) {
        if (!value.containsKey(key)) {
          out.add(
              SchemaViolation('$pointer/$key', 'required property is missing'));
        }
      }

      if (node['additionalProperties'] == false) {
        for (final key in value.keys) {
          if (!props.containsKey(key)) {
            out.add(SchemaViolation('$pointer/$key', 'unexpected property'));
          }
        }
      }

      for (final entry in value.entries) {
        final sub = props[entry.key];
        if (sub is Map) {
          _check(
            entry.value,
            sub.cast<String, dynamic>(),
            '$pointer/${_escape('${entry.key}')}',
            out,
          );
        }
      }
    }

    if (value is List) {
      final items = node['items'];
      if (items is Map) {
        final sub = items.cast<String, dynamic>();
        for (var i = 0; i < value.length; i++) {
          _check(value[i], sub, '$pointer/$i', out);
        }
      }
    }
  }

  static List<String> _typesOf(Map<String, dynamic> node) {
    final t = node['type'];
    if (t is String) return [t];
    if (t is List) return t.cast<String>();
    return const [];
  }

  static bool _matchesType(Object? value, String type) => switch (type) {
        'object' => value is Map,
        'array' => value is List,
        'string' => value is String,
        'integer' => value is int,
        'number' => value is num,
        'boolean' => value is bool,
        'null' => value == null,
        _ => throw ArgumentError('unsupported schema type "$type"'),
      };

  static String _describe(Object? value) => switch (value) {
        null => 'null',
        Map() => 'object',
        List() => 'array',
        String() => 'string',
        bool() => 'boolean',
        int() => 'integer',
        num() => 'number',
        _ => value.runtimeType.toString(),
      };

  static String _escape(String token) =>
      token.replaceAll('~', '~0').replaceAll('/', '~1');
}
