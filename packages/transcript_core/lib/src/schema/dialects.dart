import 'note_schema.dart';

/// Every provider wants the same schema in a slightly different dialect. Rather than
/// maintaining parallel copies that silently drift, the canonical schema is authored once
/// (see [noteDocumentSchema]) and each provider's shape is derived from it here.
enum SchemaDialect {
  /// JSON Schema as authored. Anthropic `output_config.format`, Ollama `format`.
  plain,

  /// OpenAI structured outputs with `strict: true`. Requires every property to appear in
  /// `required` and `additionalProperties: false` on every object — which the canonical
  /// schema already satisfies — but rejects the `$schema`/`$id` annotation keywords.
  openAiStrict,

  /// Gemini `generationConfig.responseSchema`, an OpenAPI 3.0 subset. Cannot express
  /// `$ref`, `$defs` or `additionalProperties`, and spells optionality as `nullable: true`
  /// rather than a `["string", "null"]` type union.
  gemini,
}

/// Renders the canonical NoteDocument schema in [dialect].
Map<String, dynamic> noteSchemaFor(SchemaDialect dialect) =>
    renderSchema(noteDocumentSchema, dialect);

/// Renders an arbitrary schema in [dialect]. Exposed for tests and for future schemas
/// (the sprint planner has its own).
Map<String, dynamic> renderSchema(
  Map<String, dynamic> schema,
  SchemaDialect dialect,
) {
  final defs = (schema[r'$defs'] as Map?)?.cast<String, dynamic>() ?? const {};
  final out = _walk(schema, dialect, defs, 0);
  return out as Map<String, dynamic>;
}

const _maxRefDepth = 16;

Object? _walk(
  Object? node,
  SchemaDialect dialect,
  Map<String, dynamic> defs,
  int depth,
) {
  if (node is List) {
    return node.map((e) => _walk(e, dialect, defs, depth)).toList();
  }
  if (node is! Map) return node;

  final map = node.cast<String, dynamic>();

  // Inline $ref for dialects that cannot express it. Guarded against a cyclic schema.
  final ref = map[r'$ref'];
  if (ref is String && dialect != SchemaDialect.plain) {
    if (depth >= _maxRefDepth) {
      throw StateError(
          '\$ref nesting exceeded $_maxRefDepth resolving "$ref" — '
          'the schema is probably cyclic, which no provider dialect can express.');
    }
    final target = _resolveLocalRef(ref, defs);
    // Sibling keys alongside $ref (a description, say) stay and win over the target's.
    final merged = <String, dynamic>{...target, ...map}..remove(r'$ref');
    return _walk(merged, dialect, defs, depth + 1);
  }

  final result = <String, dynamic>{};
  for (final entry in map.entries) {
    final key = entry.key;
    final value = entry.value;

    // Annotation keywords no provider accepts inside a response schema.
    if (key == r'$schema' || key == r'$id') continue;

    if (key == r'$defs') {
      // Kept only for the plain dialect; the others have had every $ref inlined above.
      if (dialect == SchemaDialect.plain) {
        result[key] = _walk(value, dialect, defs, depth);
      }
      continue;
    }

    if (key == 'additionalProperties' && dialect == SchemaDialect.gemini) {
      continue; // unsupported in the OpenAPI subset
    }

    if (key == 'type' && value is List && dialect == SchemaDialect.gemini) {
      // ["string", "null"] -> type: string + nullable: true
      final types = value.cast<String>();
      final nonNull = types.where((t) => t != 'null').toList();
      if (types.contains('null')) result['nullable'] = true;
      if (nonNull.length > 1) {
        throw StateError('Gemini responseSchema cannot express a union of '
            '${nonNull.join('|')} — express it as a single type plus nullable.');
      }
      result['type'] = nonNull.isEmpty ? 'string' : nonNull.single;
      continue;
    }

    result[key] = _walk(value, dialect, defs, depth);
  }

  // Gemini honours declaration order in `propertyOrdering`; without it the model is free to
  // emit fields in any order, which measurably hurts quality on long objects.
  if (dialect == SchemaDialect.gemini && result['properties'] is Map) {
    result['propertyOrdering'] =
        (result['properties'] as Map).keys.cast<String>().toList();
  }

  return result;
}

Map<String, dynamic> _resolveLocalRef(String ref, Map<String, dynamic> defs) {
  const prefix = r'#/$defs/';
  if (!ref.startsWith(prefix)) {
    throw StateError(
        'Only local $prefix references are supported, got "$ref".');
  }
  final name = ref.substring(prefix.length);
  final target = defs[name];
  if (target is! Map) {
    throw StateError('Unresolved schema reference "$ref".');
  }
  return target.cast<String, dynamic>();
}
