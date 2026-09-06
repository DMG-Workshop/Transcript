import '../models/note_document.dart';

/// Turns a note into something another tool can read.
///
/// One rule runs through all of these: a date the model derived is never exported as if
/// it were spoken. Once a note leaves the app the `dateBasis` field is gone, so the
/// distinction has to survive as text the receiving tool will show — otherwise the
/// honesty the whole schema was built for stops at the export button.
class NoteExporters {
  const NoteExporters._();

  /// Marks a derived date wherever one is exported.
  static const String inferredMarker =
      'inferred from the recording, not stated';

  // ---------------------------------------------------------------------------
  // Markdown — for pasting into a doc or a ticket.
  // ---------------------------------------------------------------------------

  static String markdown(NoteDocument note, {String? recordedOn}) {
    final out = StringBuffer()
      ..writeln('# ${note.meta.title}')
      ..writeln();

    if (recordedOn != null) out.writeln('*Recorded $recordedOn*\n');
    out
      ..writeln(note.meta.summary)
      ..writeln();

    if (note.meta.extractionConfidence != ExtractionConfidence.high) {
      out
        ..writeln('> Parts of the audio were unclear, so these notes may be '
            'incomplete.')
        ..writeln();
    }

    for (final section in note.sections) {
      out.writeln('## ${section.heading}');
      for (final bullet in section.bullets) {
        out.writeln('- $bullet');
      }
      out.writeln();
    }

    if (note.decisions.isNotEmpty) {
      out.writeln('## Decisions');
      for (final decision in note.decisions) {
        out.writeln('- ${decision.statement}');
        out.writeln('  > "${decision.sourceRef.quote}"');
      }
      out.writeln();
    }

    if (note.tasks.isNotEmpty) {
      out.writeln('## Action items');
      for (final task in note.tasks) {
        out.writeln('- [${task.status == TaskStatus.done ? 'x' : ' '}] '
            '${task.title}${_ownerSuffix(task, note)}${_dueSuffix(task)}');
      }
      out.writeln();
    }

    if (note.openQuestions.isNotEmpty) {
      out.writeln('## Open questions');
      for (final question in note.openQuestions) {
        out.writeln('- ${question.question}');
      }
      out.writeln();
    }

    if (note.risks.isNotEmpty) {
      out.writeln('## Risks');
      for (final risk in note.risks) {
        out.writeln('- **${risk.severity.name}** — ${risk.description}');
      }
      out.writeln();
    }

    return out.toString().trimRight();
  }

  static String _ownerSuffix(NoteTask task, NoteDocument note) {
    final owner = _ownerName(task, note);
    return owner == null ? '' : ' — $owner';
  }

  static String _dueSuffix(NoteTask task) => switch (task.dateBasis) {
        DateBasis.explicit => ' (due ${task.dueDate})',
        DateBasis.inferred => ' (due ${task.dueDate}, $inferredMarker)',
        DateBasis.absent => ' (no date discussed)',
      };

  // ---------------------------------------------------------------------------
  // CSV — a plain task list.
  // ---------------------------------------------------------------------------

  static String tasksCsv(NoteDocument note) {
    final rows = <List<String>>[
      [
        'Title',
        'Owner',
        'Status',
        'Priority',
        'Start',
        'Due',
        'Date basis',
        'Quote'
      ],
      for (final task in note.tasks)
        [
          task.title,
          _ownerName(task, note) ?? '',
          task.status.name,
          task.priority.name,
          task.startDate ?? '',
          task.dueDate ?? '',
          // Exported as its own column rather than folded into the date, so a
          // spreadsheet can filter on it.
          task.dateBasis.name,
          task.sourceRef.quote,
        ],
    ];
    return rows.map((r) => r.map(_csvCell).join(',')).join('\r\n');
  }

  /// Jira's CSV importer, which expects its own column names.
  static String jiraCsv(NoteDocument note) {
    final rows = <List<String>>[
      [
        'Summary',
        'Description',
        'Assignee',
        'Priority',
        'Due Date',
        'Issue Type'
      ],
      for (final task in note.tasks)
        [
          task.title,
          _jiraDescription(task),
          _ownerName(task, note) ?? '',
          _jiraPriority(task.priority),
          // A derived date is deliberately not exported into a field Jira will treat as
          // committed. It stays in the description where a human reads it.
          task.dateBasis == DateBasis.explicit ? (task.dueDate ?? '') : '',
          'Task',
        ],
    ];
    return rows.map((r) => r.map(_csvCell).join(',')).join('\r\n');
  }

  static String _jiraDescription(NoteTask task) {
    final parts = <String>[
      if (task.detail != null) task.detail!,
      'From the recording: "${task.sourceRef.quote}"',
      if (task.dateBasis == DateBasis.inferred)
        'Due around ${task.dueDate} — $inferredMarker.',
      if (task.dateBasis == DateBasis.absent) 'No date was discussed.',
    ];
    return parts.join('\n\n');
  }

  static String _jiraPriority(TaskPriority priority) => switch (priority) {
        TaskPriority.critical => 'Highest',
        TaskPriority.high => 'High',
        TaskPriority.medium => 'Medium',
        TaskPriority.low => 'Low',
      };

  /// RFC 4180: quote every field, double any embedded quote.
  static String _csvCell(String value) =>
      '"${value.replaceAll('"', '""').replaceAll('\r\n', ' ').replaceAll('\n', ' ')}"';

  // ---------------------------------------------------------------------------
  // iCalendar — tasks as VTODOs, milestones as all-day events.
  // ---------------------------------------------------------------------------

  static String ics(NoteDocument note, {DateTime? stamp}) {
    final now = _icsDateTime(stamp ?? DateTime.now().toUtc());
    final out = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//Transcript//Notes//EN')
      ..writeln('CALSCALE:GREGORIAN');

    for (final task in note.tasks) {
      // Only dated tasks become calendar entries. An undated one would have to be given
      // a date to exist here at all, so it is left out rather than invented.
      if (task.dueDate == null || task.dateBasis == DateBasis.absent) continue;

      out
        ..writeln('BEGIN:VTODO')
        ..writeln('UID:${task.id}@transcript.app')
        ..writeln('DTSTAMP:$now')
        ..writeln('SUMMARY:${_icsText(task.title)}')
        ..writeln('DUE;VALUE=DATE:${_icsDate(task.dueDate!)}')
        ..writeln(
            'STATUS:${task.status == TaskStatus.done ? 'COMPLETED' : 'NEEDS-ACTION'}')
        ..writeln('DESCRIPTION:${_icsText(_jiraDescription(task))}')
        ..writeln('END:VTODO');
    }

    for (final anchor in note.timelineAnchors) {
      out
        ..writeln('BEGIN:VEVENT')
        ..writeln('UID:${_slug(anchor.label)}@transcript.app')
        ..writeln('DTSTAMP:$now')
        ..writeln('DTSTART;VALUE=DATE:${_icsDate(anchor.date)}')
        ..writeln('SUMMARY:${_icsText(anchor.label)}')
        ..writeln('END:VEVENT');
    }

    out.writeln('END:VCALENDAR');
    // iCalendar wants CRLF line endings.
    return out.toString().replaceAll('\n', '\r\n');
  }

  static String _icsDate(String iso) => iso.replaceAll('-', '');

  static String _icsDateTime(DateTime utc) =>
      '${_icsDate(utc.toIso8601String().substring(0, 10))}'
      'T${utc.toIso8601String().substring(11, 19).replaceAll(':', '')}Z';

  /// RFC 5545 escaping: backslash, semicolon, comma and newline are all special.
  static String _icsText(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll(';', r'\;')
      .replaceAll(',', '\\,')
      .replaceAll('\r\n', '\\n')
      .replaceAll('\n', '\\n');

  static String _slug(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  static String? _ownerName(NoteTask task, NoteDocument note) {
    if (task.assigneeRaw != null) return task.assigneeRaw;
    if (task.assigneeId == null) return null;
    for (final p in note.participants) {
      if (p.id == task.assigneeId) return p.displayName;
    }
    return null;
  }
}
