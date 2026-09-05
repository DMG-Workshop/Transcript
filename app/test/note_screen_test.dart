import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/data/database.dart' as db;
import 'package:transcript_app/src/recording/recording_controller.dart';
import 'package:transcript_app/src/screens/note_screen.dart';

import 'fixtures.dart';

void main() {
  Future<void> pumpNote(WidgetTester tester, db.Recording recording) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingsProvider.overrideWith((ref) => Stream.value([recording])),
        ],
        child: const MaterialApp(home: NoteScreen(recordingId: 'r_1')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the summary and bullets', (tester) async {
    await pumpNote(tester, recordingRow());

    expect(find.text('Auth migration kickoff'), findsWidgets);
    expect(
      find.text('The team agreed to retire the legacy session store before launch.'),
      findsOneWidget,
    );
    expect(find.text('Priya owns the migration.'), findsOneWidget);
  });

  testWidgets('shows a decision with the words it came from', (tester) async {
    await pumpNote(tester, recordingRow());

    expect(find.text('Retire the legacy session store before launch.'), findsOneWidget);
    expect(find.text('“we are retiring it before launch, agreed”'), findsOneWidget,
        reason: 'provenance is shown, not hidden behind a tap');
  });

  testWidgets('a spoken date and an undated task are rendered differently',
      (tester) async {
    await pumpNote(tester, recordingRow());
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();

    expect(find.text('2026-09-18'), findsOneWidget);
    expect(find.text('no date discussed'), findsOneWidget);
    expect(find.text('No date discussed'), findsOneWidget,
        reason: 'undated tasks get their own section rather than a guessed date');
    expect(
      find.textContaining('nothing has been guessed'),
      findsOneWidget,
    );
  });

  testWidgets('an inferred date is labelled as inferred', (tester) async {
    final note = noteJson();
    final task = (note['tasks'] as List<dynamic>).first as Map<String, dynamic>;
    task['dateBasis'] = 'inferred';
    task['dueDate'] = '2026-09-30';

    await pumpNote(tester, recordingRow(overrideNote: jsonEncode(note)));
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();

    expect(find.text('2026-09-30 · inferred'), findsOneWidget,
        reason: 'a derived date must never look like one that was spoken');
  });

  testWidgets('the owner is shown when someone took the work', (tester) async {
    await pumpNote(tester, recordingRow());
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();

    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets('unclear audio is flagged rather than presented as clean',
      (tester) async {
    final note = noteJson();
    (note['meta'] as Map<String, dynamic>)['extractionConfidence'] = 'low';

    await pumpNote(tester, recordingRow(overrideNote: jsonEncode(note)));
    expect(find.textContaining('hard to make out'), findsOneWidget);
  });

  testWidgets('no action items says so plainly instead of showing an empty list',
      (tester) async {
    final note = noteJson()..['tasks'] = <Object>[];

    await pumpNote(tester, recordingRow(overrideNote: jsonEncode(note)));
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No action items'), findsOneWidget);
  });

  testWidgets('a recording whose structuring failed still opens', (tester) async {
    await pumpNote(tester, recordingRow(structured: false));

    expect(find.text('No notes for this recording'), findsOneWidget);
    expect(find.textContaining('still saved'), findsOneWidget,
        reason: 'the user must be told the recording survived');
  });

  testWidgets('the transcript tab traces items back to their timestamps',
      (tester) async {
    await pumpNote(tester, recordingRow());
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();

    expect(find.text('00:12'), findsOneWidget);
    expect(find.text('“we need to get off the legacy session store”'), findsOneWidget);
  });

  testWidgets('shows which services made the note and what it cost', (tester) async {
    await pumpNote(tester, recordingRow());
    await tester.dragUntilVisible(
      find.textContaining('Transcribed by'),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('on-device'), findsOneWidget);
    expect(find.textContaining('1.8k in'), findsOneWidget,
        reason: 'users spending their own API credit are owed the measured tokens');
    expect(find.textContaining('≈\$'), findsOneWidget,
        reason: 'a known model gets a price, marked approximate');
  });

  testWidgets('a recording that no longer exists does not crash', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingsProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: const MaterialApp(home: NoteScreen(recordingId: 'r_gone')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('no longer here'), findsOneWidget);
  });
}
