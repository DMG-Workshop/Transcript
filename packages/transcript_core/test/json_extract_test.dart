import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  test('clean JSON passes through', () {
    expect(extractJsonObject('{"a":1}'), equals({'a': 1}));
  });

  test('strips a markdown fence', () {
    expect(
      extractJsonObject('```json\n{"a":1}\n```'),
      equals({'a': 1}),
    );
  });

  test('strips a fence with no language tag', () {
    expect(extractJsonObject('```\n{"a":1}\n```'), equals({'a': 1}));
  });

  test('survives a conversational preamble and a sign-off', () {
    expect(
      extractJsonObject(
          'Here is the structured note:\n\n{"a":1}\n\nLet me know!'),
      equals({'a': 1}),
    );
  });

  test('handles nested objects', () {
    expect(
      extractJsonObject('noise {"a":{"b":[1,2,{"c":3}]}} more noise'),
      equals({
        'a': {
          'b': [
            1,
            2,
            {'c': 3}
          ]
        }
      }),
    );
  });

  test('braces inside string values do not confuse the scanner', () {
    final result =
        extractJsonObject(r'prefix {"quote":"he said {this} and \"that\""}');
    expect(result?['quote'], r'he said {this} and "that"');
  });

  test('returns null when there is no object at all', () {
    expect(extractJsonObject('I cannot help with that.'), isNull);
  });

  test('returns null for a truncated object rather than guessing', () {
    expect(extractJsonObject('{"a":1, "b":'), isNull);
  });

  test('returns null for a bare array — the schema root is an object', () {
    expect(extractJsonObject('[1,2,3]'), isNull);
  });
}
