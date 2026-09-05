import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  group('canonical schema', () {
    test('matches the copy published in docs/', () {
      // The Dart constant is the source of truth; the docs file is generated from it by
      // tool/export_schema.dart. If this fails, run that tool.
      final file = File('../../docs/schemas/note-document.schema.json');
      expect(file.existsSync(), isTrue, reason: 'docs schema missing');
      expect(
        json.decode(file.readAsStringSync()),
        equals(noteDocumentSchema),
        reason:
            'docs/schemas/note-document.schema.json has drifted from the Dart '
            'source — run: dart run tool/export_schema.dart',
      );
    });

    test('is strict-mode compatible: every property is required everywhere',
        () {
      final offenders = <String>[];
      void walk(Object? node, String path) {
        if (node is List) {
          for (var i = 0; i < node.length; i++) {
            walk(node[i], '$path/$i');
          }
          return;
        }
        if (node is! Map<String, dynamic>) return;

        if (node['type'] == 'object' && node['properties'] is Map) {
          final props =
              (node['properties'] as Map).keys.map((k) => '$k').toSet();
          final required = ((node['required'] as List?) ?? const [])
              .map((k) => '$k')
              .toSet();
          final missing = props.difference(required);
          if (missing.isNotEmpty) offenders.add('$path: ${missing.join(', ')}');
          if (node['additionalProperties'] != false) {
            offenders.add('$path: additionalProperties is not false');
          }
        }
        node.forEach((k, v) => walk(v, '$path/$k'));
      }

      walk(noteDocumentSchema, '');
      expect(offenders, isEmpty,
          reason:
              'OpenAI strict mode rejects optional properties; express optionality '
              'as a nullable type union instead');
    });

    test('dateBasis is required on every task and offers exactly three values',
        () {
      final task = ((noteDocumentSchema['properties']
          as Map<String, dynamic>)['tasks'] as Map<String, dynamic>)['items'];
      final props =
          (task as Map<String, dynamic>)['properties'] as Map<String, dynamic>;
      expect((task['required'] as List), contains('dateBasis'));
      expect(
        (props['dateBasis'] as Map<String, dynamic>)['enum'],
        equals(['explicit', 'inferred', 'absent']),
      );
    });

    test('every extractable item requires a sourceRef', () {
      const extractable = [
        'sections',
        'decisions',
        'openQuestions',
        'tasks',
        'risks',
        'timelineAnchors'
      ];
      final props = noteDocumentSchema['properties'] as Map<String, dynamic>;
      for (final key in extractable) {
        final items = (props[key] as Map<String, dynamic>)['items']
            as Map<String, dynamic>;
        expect((items['required'] as List), contains('sourceRef'),
            reason: '$key items must cite the transcript');
      }
    });
  });

  group('dialects', () {
    test('plain keeps \$defs and \$ref intact', () {
      final plain = noteSchemaFor(SchemaDialect.plain);
      expect(plain.containsKey(r'$defs'), isTrue);
      expect(plain.containsKey(r'$schema'), isFalse,
          reason: 'annotation keywords are stripped for every provider');
      final task = _taskItems(plain);
      expect((task['properties'] as Map)['sourceRef'], contains(r'$ref'));
    });

    test('openAiStrict inlines \$ref and drops \$defs', () {
      final strict = noteSchemaFor(SchemaDialect.openAiStrict);
      expect(strict.containsKey(r'$defs'), isFalse);
      expect(_keysAnywhere(strict), isNot(contains(r'$ref')));

      final sourceRef = (_taskItems(strict)['properties']
          as Map<String, dynamic>)['sourceRef'] as Map<String, dynamic>;
      expect((sourceRef['properties'] as Map).keys, contains('quote'));
      expect(sourceRef['additionalProperties'], isFalse);
    });

    test('openAiStrict keeps nullable type unions, which strict mode accepts',
        () {
      final props =
          _taskItems(noteSchemaFor(SchemaDialect.openAiStrict))['properties']
              as Map<String, dynamic>;
      expect((props['dueDate'] as Map<String, dynamic>)['type'],
          equals(['string', 'null']));
    });

    test('gemini converts nullable unions and drops unsupported keywords', () {
      final gemini = noteSchemaFor(SchemaDialect.gemini);

      // Checked on keys, not on the encoded string — the schema's own prose mentions
      // these keywords, and a substring match would fail on the documentation.
      expect(_keysAnywhere(gemini), isNot(contains(r'$ref')));
      expect(_keysAnywhere(gemini), isNot(contains(r'$defs')));
      expect(_keysAnywhere(gemini), isNot(contains('additionalProperties')),
          reason: 'the OpenAPI 3.0 subset has no additionalProperties');

      final props = _taskItems(gemini)['properties'] as Map<String, dynamic>;
      final dueDate = props['dueDate'] as Map<String, dynamic>;
      expect(dueDate['type'], equals('string'));
      expect(dueDate['nullable'], isTrue);
    });

    test('gemini emits propertyOrdering so field order is stable', () {
      final gemini = noteSchemaFor(SchemaDialect.gemini);
      expect(gemini['propertyOrdering'],
          equals((gemini['properties'] as Map).keys.toList()));
    });

    test(
        'unresolvable \$ref fails loudly rather than silently dropping a field',
        () {
      expect(
        () => renderSchema({
          'type': 'object',
          'properties': {
            'x': {r'$ref': '#/\$defs/missing'}
          },
        }, SchemaDialect.gemini),
        throwsA(isA<StateError>()),
      );
    });
  });
}

Map<String, dynamic> _taskItems(Map<String, dynamic> schema) =>
    ((schema['properties'] as Map<String, dynamic>)['tasks']
        as Map<String, dynamic>)['items'] as Map<String, dynamic>;

/// Every property key appearing anywhere in a schema tree. Used instead of a substring
/// search so the schema's own descriptions cannot trip the assertions.
Set<String> _keysAnywhere(Object? node) {
  final keys = <String>{};
  void walk(Object? n) {
    if (n is List) {
      n.forEach(walk);
    } else if (n is Map<String, dynamic>) {
      keys.addAll(n.keys);
      n.values.forEach(walk);
    }
  }

  walk(node);
  return keys;
}
