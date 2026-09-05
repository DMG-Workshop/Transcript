import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  final validator = SchemaValidator(noteDocumentSchema);

  test('a well-formed note validates', () {
    expect(validator.validate(validNoteJson()), isEmpty);
  });

  test('reports a missing required property with a usable pointer', () {
    final doc = validNoteJson();
    ((doc['tasks'] as List<dynamic>).first as Map<String, dynamic>)
        .remove('dueDate');

    final errors = validator.validate(doc);
    expect(errors, hasLength(1));
    expect(errors.single.pointer, '/tasks/0/dueDate');
    expect(errors.single.message, contains('required'));
  });

  test('reports a bad enum value, listing what was allowed', () {
    final doc = validNoteJson();
    ((doc['tasks'] as List<dynamic>).first
        as Map<String, dynamic>)['dateBasis'] = 'probably';

    final errors = validator.validate(doc);
    expect(errors.single.pointer, '/tasks/0/dateBasis');
    expect(errors.single.message, contains('explicit'));
  });

  test('reports a wrong type', () {
    final doc = validNoteJson();
    ((doc['tasks'] as List<dynamic>).first as Map<String, dynamic>)['title'] =
        42;

    final errors = validator.validate(doc);
    expect(errors.single.pointer, '/tasks/0/title');
    expect(errors.single.message, contains('expected string'));
  });

  test('accepts null where the schema allows a nullable union', () {
    final doc = validNoteJson();
    ((doc['tasks'] as List<dynamic>).first
        as Map<String, dynamic>)['assigneeId'] = null;
    expect(validator.validate(doc), isEmpty);
  });

  test('rejects a property the schema does not define', () {
    final doc = validNoteJson();
    ((doc['tasks'] as List<dynamic>).first
        as Map<String, dynamic>)['confidence'] = 0.9;

    final errors = validator.validate(doc);
    expect(errors.single.pointer, '/tasks/0/confidence');
    expect(errors.single.message, contains('unexpected'));
  });

  test('validates through a \$ref into \$defs', () {
    final doc = validNoteJson();
    final task = (doc['tasks'] as List<dynamic>).first as Map<String, dynamic>;
    (task['sourceRef'] as Map<String, dynamic>)['quote'] = 17;

    final errors = validator.validate(doc);
    expect(errors.single.pointer, '/tasks/0/sourceRef/quote');
  });

  test('collects every violation rather than stopping at the first', () {
    final doc = validNoteJson();
    final task = (doc['tasks'] as List<dynamic>).first as Map<String, dynamic>;
    task
      ..remove('epic')
      ..['status'] = 'maybe'
      ..['priority'] = 'urgent';

    expect(validator.validate(doc), hasLength(3));
  });

  test('an integer is a valid number but a double is not a valid integer', () {
    final schema = SchemaValidator({
      'type': 'object',
      'additionalProperties': false,
      'required': ['n', 'i'],
      'properties': {
        'n': {'type': 'number'},
        'i': {'type': 'integer'},
      },
    });
    expect(schema.validate({'n': 3, 'i': 3}), isEmpty);
    expect(schema.validate({'n': 3.5, 'i': 3}), isEmpty);
    expect(schema.validate({'n': 3, 'i': 3.5}), hasLength(1));
  });
}
