import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/recording/recording_controller.dart';
import 'package:transcript_app/src/screens/export_sheet.dart';
import 'package:transcript_app/src/screens/note_screen.dart';
import 'package:transcript_app/src/screens/timeline_view.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!;
    view.physicalSize = const Size(1400, 1400);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .implicitView!;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<void> pumpTimeline(WidgetTester tester,
      {Map<String, dynamic>? note}) async {
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
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
  }

  testWidgets('a dated task is drawn and named on the chart', (tester) async {
    await pumpTimeline(tester);

    expect(find.byType(TimelinePainter), findsNothing,
        reason: 'the painter is not a widget');
    expect(find.byType(CustomPaint), findsWidgets);
    expect(
      find.text('Migrate the auth service off the legacy session store'),
      findsOneWidget,
      reason: 'a bar with no visible name is not worth drawing',
    );
  });

  testWidgets('undated work goes to a tray that says nothing was guessed',
      (tester) async {
    await pumpTimeline(tester);

    expect(find.text('Needs dates'), findsOneWidget);
    expect(find.textContaining('nothing has been guessed'), findsOneWidget);
    expect(find.text('Update the runbook'), findsOneWidget,
        reason: 'the undated task is offered for dating, not placed on the chart');
  });

  testWidgets('the scale can be switched between day, week and month',
      (tester) async {
    await pumpTimeline(tester);

    for (final label in ['Day', 'Week', 'Month']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chart carrying inferred dates says how many', (tester) async {
    final note = noteJson();
    final task = (note['tasks'] as List<dynamic>).first as Map<String, dynamic>;
    task['dateBasis'] = 'inferred';
    task['dueDate'] = '2026-09-30';

    await pumpTimeline(tester, note: note);

    expect(find.textContaining('1 inferred'), findsOneWidget,
        reason: 'the reader must not assume everything on the chart was spoken');
  });

  testWidgets('a note with no dates at all shows an empty chart, not a broken one',
      (tester) async {
    final note = noteJson();
    for (final t in note['tasks'] as List<dynamic>) {
      (t as Map<String, dynamic>)
        ..['dateBasis'] = 'absent'
        ..['dueDate'] = null
        ..['startDate'] = null;
    }
    note['timelineAnchors'] = <Object>[];

    await pumpTimeline(tester, note: note);

    expect(find.text('Nothing on the timeline yet'), findsOneWidget);
    expect(find.textContaining('No dates were discussed'), findsOneWidget);
    expect(find.text('Needs dates'), findsOneWidget,
        reason: 'the tray still offers the undated work');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping an undated task opens the editor to place it',
      (tester) async {
    await pumpTimeline(tester);

    await tester.tap(find.widgetWithText(ActionChip, 'Update the runbook'));
    await tester.pumpAndSettle();

    expect(find.text('Edit task'), findsOneWidget);
    expect(find.text('No date discussed'), findsOneWidget);
  });

  testWidgets('the export sheet offers every format and flags inferred dates',
      (tester) async {
    final note = noteJson();
    final task = (note['tasks'] as List<dynamic>).first as Map<String, dynamic>;
    task['dateBasis'] = 'inferred';
    task['dueDate'] = '2026-09-30';

    await pumpTimeline(tester, note: note);

    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();

    expect(find.text('Markdown'), findsOneWidget);
    expect(find.text('Spreadsheet (CSV)'), findsOneWidget);
    expect(find.text('Jira CSV'), findsOneWidget);
    expect(find.text('Calendar (.ics)'), findsOneWidget);
    expect(find.textContaining('was inferred from the recording'), findsOneWidget,
        reason: 'the warning has to survive the trip out of the app');
  });

  test('every export format renders without throwing', () {
    final note = NoteDocument.fromJson(noteJson());
    for (final format in ExportFormat.values) {
      final rendered = format.render(note, recordedOn: '5 Sep 2026');
      expect(rendered, isNotEmpty, reason: '${format.label} produced nothing');
    }
  });
}
