import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/screens/board_view.dart';
import 'package:transcript_app/src/screens/note_screen.dart';
import 'package:transcript_app/src/recording/recording_controller.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!;
    // Wide enough for several columns; the board scrolls horizontally on a phone.
    view.physicalSize = const Size(1400, 1200);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<void> pumpBoard(WidgetTester tester, {Map<String, dynamic>? note}) async {
    final row = recordingRow(
      overrideNote: note == null ? null : jsonEncode(note),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          recordingsProvider.overrideWith((ref) => Stream.value([row])),
        ],
        child: const MaterialApp(home: NoteScreen(recordingId: 'r_1')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Board'));
    await tester.pumpAndSettle();
  }

  testWidgets('every column is present, including the empty ones', (tester) async {
    await pumpBoard(tester);

    for (final label in ['To do', 'In progress', 'Blocked', 'Done']) {
      expect(find.text(label), findsOneWidget,
          reason: 'a column that vanishes when empty cannot be dropped into');
    }
  });

  testWidgets('cards land in the column their status names', (tester) async {
    final note = noteJson();
    ((note['tasks'] as List<dynamic>)[1] as Map<String, dynamic>)['status'] = 'done';

    await pumpBoard(tester, note: note);

    expect(find.text('Migrate the auth service off the legacy session store'),
        findsOneWidget);
    expect(find.text('Update the runbook'), findsOneWidget);
  });

  testWidgets('the board is the same tasks as the notes, not a second extraction',
      (tester) async {
    await pumpBoard(tester);

    // Both cards from the fixture appear; the columns are a group-by, nothing more.
    expect(find.byType(TaskCard), findsNWidgets(2));
  });

  testWidgets('a long-press drag is offered on each card', (tester) async {
    await pumpBoard(tester);
    expect(find.byType(LongPressDraggable<NoteTask>), findsNWidgets(2),
        reason: 'a plain drag would fight the column scroll view');
  });

  testWidgets('filtering by owner hides work belonging to nobody', (tester) async {
    await pumpBoard(tester);

    await tester.tap(find.widgetWithText(FilterChip, 'Priya'));
    await tester.pumpAndSettle();

    expect(find.text('Migrate the auth service off the legacy session store'),
        findsOneWidget);
    expect(find.text('Update the runbook'), findsNothing);
  });

  testWidgets('unowned work can be surfaced on its own', (tester) async {
    await pumpBoard(tester);

    await tester.tap(find.widgetWithText(FilterChip, 'Unassigned'));
    await tester.pumpAndSettle();

    // "Somebody should update the runbook" is the commitment nobody took.
    expect(find.text('Update the runbook'), findsOneWidget);
    expect(find.text('Migrate the auth service off the legacy session store'),
        findsNothing);
  });

  testWidgets('the count of undated tasks is shown', (tester) async {
    await pumpBoard(tester);
    expect(find.textContaining('1 need dates'), findsOneWidget);
  });

  testWidgets('the editor opens for an existing task', (tester) async {
    await pumpBoard(tester);

    await tester.tap(find.text('Update the runbook'));
    await tester.pumpAndSettle();

    expect(find.text('Edit task'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'What needs doing'), findsOneWidget);
    expect(find.text('No date discussed'), findsOneWidget,
        reason: 'the editor states the absence rather than defaulting to today');
  });

  testWidgets('adding a task starts a blank editor in that column', (tester) async {
    await pumpBoard(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.add).first);
    await tester.pumpAndSettle();

    expect(find.text('New task'), findsOneWidget);
    final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'What needs doing'));
    expect(field.controller?.text, isEmpty);
  });

  testWidgets('an empty board offers to add a task by hand', (tester) async {
    await pumpBoard(tester, note: noteJson()..['tasks'] = <Object>[]);

    expect(find.textContaining('No action items'), findsOneWidget);
    await tester.tap(find.text('Add one yourself'));
    await tester.pumpAndSettle();

    expect(find.text('New task'), findsOneWidget);
  });
}
