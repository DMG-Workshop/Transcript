import 'dart:convert';
import 'dart:io';

import 'package:transcript_core/transcript_core.dart';

/// Writes `docs/schemas/note-document.schema.json` from the Dart source of truth.
/// `test/schema_sync_test.dart` fails the build if the two have drifted.
void main() {
  final target = File('../../docs/schemas/note-document.schema.json');
  const encoder = JsonEncoder.withIndent('  ');
  target.writeAsStringSync('${encoder.convert(noteDocumentSchema)}\n');
  stdout.writeln('Wrote ${target.path}');
}
