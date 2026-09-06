import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  final note = NoteDocument.fromJson(validNoteJson());

  Map<String, dynamic> taskJson({
    required String id,
    String? due,
    String basis = 'explicit',
    String title = 'Do the thing',
  }) =>
      {
        'id': id,
        'title': title,
        'detail': null,
        'assigneeId': null,
        'assigneeRaw': null,
        'status': 'todo',
        'priority': 'medium',
        'estimate': null,
        'startDate': null,
        'dueDate': due,
        'dateBasis': basis,
        'dependsOn': <String>[],
        'epic': null,
        'sourceRef': {'startMs': 0, 'endMs': 1, 'quote': 'said in the meeting'},
      };

  NoteDocument withTasks(List<Map<String, dynamic>> tasks) =>
      NoteDocument.fromJson(validNoteJson()..['tasks'] = tasks);

  group('markdown', () {
    test('carries the title, summary and sections', () {
      final md = NoteExporters.markdown(note);
      expect(md, startsWith('# Auth migration kickoff'));
      expect(md, contains('## Auth migration'));
      expect(md, contains('- The legacy session store is being retired'));
    });

    test('action items are checkboxes with owner and due date', () {
      final md = NoteExporters.markdown(note);
      expect(md, contains('- [ ] Migrate the auth service'));
      expect(md, contains('— Priya'));
      expect(md, contains('(due 2026-09-18)'));
    });

    test('a derived date says so, even outside the app', () {
      final md = NoteExporters.markdown(
        withTasks([taskJson(id: 't', due: '2026-09-30', basis: 'inferred')]),
      );
      expect(md, contains(NoteExporters.inferredMarker),
          reason: 'dateBasis does not survive the export, so the words must');
    });

    test('an undated task says no date was discussed rather than being dropped',
        () {
      final md = NoteExporters.markdown(
        withTasks([taskJson(id: 't', basis: 'absent')]),
      );
      expect(md, contains('Do the thing'));
      expect(md, contains('no date discussed'));
    });

    test('decisions carry the words they came from', () {
      expect(NoteExporters.markdown(note),
          contains('we are retiring it before launch, agreed'));
    });

    test('unclear audio is flagged in the export too', () {
      final unclear = validNoteJson();
      (unclear['meta'] as Map<String, dynamic>)['extractionConfidence'] = 'low';
      expect(NoteExporters.markdown(NoteDocument.fromJson(unclear)),
          contains('may be incomplete'));
    });
  });

  group('CSV', () {
    test('has a header and one row per task', () {
      final csv = NoteExporters.tasksCsv(note);
      final lines = csv.split('\r\n');
      expect(lines.first, startsWith('"Title","Owner"'));
      expect(lines, hasLength(note.tasks.length + 1));
    });

    test('date basis is its own column so a spreadsheet can filter on it', () {
      final csv = NoteExporters.tasksCsv(
        withTasks([taskJson(id: 't', due: '2026-09-30', basis: 'inferred')]),
      );
      expect(csv, contains('"inferred"'));
    });

    test('a quote containing a comma and a quote mark survives escaping', () {
      final tricky = taskJson(id: 't', due: '2026-09-18');
      tricky['title'] = 'Ship it, then tell "everyone"';
      final csv = NoteExporters.tasksCsv(withTasks([tricky]));

      expect(csv, contains('"Ship it, then tell ""everyone"""'));
      // One header line plus exactly one data line: the comma must not split the row.
      expect(csv.split('\r\n'), hasLength(2));
    });

    test('a newline inside a field does not break the row', () {
      final tricky = taskJson(id: 't', due: '2026-09-18');
      tricky['title'] = 'First line\nsecond line';
      expect(NoteExporters.tasksCsv(withTasks([tricky])).split('\r\n'),
          hasLength(2));
    });
  });

  group('Jira CSV', () {
    test('uses the column names Jira expects', () {
      expect(NoteExporters.jiraCsv(note).split('\r\n').first,
          '"Summary","Description","Assignee","Priority","Due Date","Issue Type"');
    });

    test('a spoken date fills the due date field', () {
      final csv = NoteExporters.jiraCsv(
        withTasks([taskJson(id: 't', due: '2026-09-18')]),
      );
      expect(csv, contains('"2026-09-18"'));
    });

    test('a derived date is kept out of the due date field', () {
      final csv = NoteExporters.jiraCsv(
        withTasks([taskJson(id: 't', due: '2026-09-30', basis: 'inferred')]),
      );

      final row = csv.split('\r\n')[1];
      expect(row, contains(NoteExporters.inferredMarker),
          reason: 'the reader still needs to know a date was suggested');
      expect(row, isNot(contains('"2026-09-30","Task"')),
          reason:
              'Jira would treat a due date as committed, and nobody committed to it');
    });

    test('priorities map onto Jira names', () {
      final high = taskJson(id: 't', due: '2026-09-18')
        ..['priority'] = 'critical';
      expect(NoteExporters.jiraCsv(withTasks([high])), contains('"Highest"'));
    });
  });

  group('iCalendar', () {
    final ics =
        NoteExporters.ics(note, stamp: DateTime.utc(2026, 9, 5, 12, 30));

    test('is a well-formed calendar with CRLF endings', () {
      expect(ics, startsWith('BEGIN:VCALENDAR\r\n'));
      expect(ics.trimRight(), endsWith('END:VCALENDAR'));
      expect(ics, contains('VERSION:2.0'));
      expect(
          ics.split('\n').every((l) => l.isEmpty || l.endsWith('\r')), isTrue);
    });

    test('a dated task becomes a VTODO with a date-valued due', () {
      expect(ics, contains('BEGIN:VTODO'));
      expect(ics, contains('DUE;VALUE=DATE:20260918'));
    });

    test('a milestone becomes an all-day event', () {
      expect(ics, contains('BEGIN:VEVENT'));
      expect(ics, contains('DTSTART;VALUE=DATE:20261001'));
      expect(ics, contains('SUMMARY:Launch'));
    });

    test('an undated task is left out rather than given a date', () {
      final calendar = NoteExporters.ics(
        withTasks([taskJson(id: 't', basis: 'absent')]),
        stamp: DateTime.utc(2026, 9, 5),
      );
      expect(calendar, isNot(contains('BEGIN:VTODO')),
          reason: 'it would have to be invented a date to exist here at all');
    });

    test('a derived date reaches the calendar but says it was derived', () {
      final calendar = NoteExporters.ics(
        withTasks([taskJson(id: 't', due: '2026-09-30', basis: 'inferred')]),
        stamp: DateTime.utc(2026, 9, 5),
      );
      expect(calendar, contains('DUE;VALUE=DATE:20260930'));
      // The comma in the marker is escaped per RFC 5545, so match the part before it.
      expect(calendar, contains('inferred from the recording'));
      expect(calendar, contains(r'recording\, not stated'),
          reason: 'the escaping must not swallow the qualifier');
    });

    test('special characters in a title are escaped per RFC 5545', () {
      final tricky = taskJson(id: 't', due: '2026-09-18');
      tricky['title'] = 'Ship; then tell, everyone\\anyway';
      final calendar = NoteExporters.ics(withTasks([tricky]),
          stamp: DateTime.utc(2026, 9, 5));

      expect(
          calendar, contains(r'SUMMARY:Ship\; then tell\, everyone\\anyway'));
    });

    test('a completed task exports as completed', () {
      final done = taskJson(id: 't', due: '2026-09-18')..['status'] = 'done';
      expect(
        NoteExporters.ics(withTasks([done]), stamp: DateTime.utc(2026, 9, 5)),
        contains('STATUS:COMPLETED'),
      );
    });
  });
}
