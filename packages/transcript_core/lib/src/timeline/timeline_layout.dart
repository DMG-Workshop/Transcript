import '../models/note_document.dart';

/// How much calendar the timeline shows at once.
enum TimelineScale {
  day(daysPerColumn: 1, label: 'Day'),
  week(daysPerColumn: 7, label: 'Week'),
  month(daysPerColumn: 30, label: 'Month');

  const TimelineScale({required this.daysPerColumn, required this.label});

  final int daysPerColumn;
  final String label;
}

/// One task placed on the timeline.
class TimelineBar {
  const TimelineBar({
    required this.taskId,
    required this.title,
    required this.start,
    required this.end,
    required this.basis,
    required this.row,
    this.assigneeId,
    this.epic,
  });

  final String taskId;
  final String title;
  final DateTime start;
  final DateTime end;

  /// Drives how the bar is drawn, and it is never inferred from the dates alone: a date
  /// the model derived and a date someone spoke look identical as values, and the whole
  /// point of the timeline is that they must not look identical on screen.
  final DateBasis basis;

  final int row;
  final String? assigneeId;
  final String? epic;

  int get durationDays => end.difference(start).inDays + 1;
}

/// A fixed date that is not itself a task — a launch, a sprint boundary, a deadline.
class TimelineMilestone {
  const TimelineMilestone({required this.label, required this.date});
  final String label;
  final DateTime date;
}

/// A stated dependency, drawn as an arrow between two bars.
class TimelineLink {
  const TimelineLink({required this.fromTaskId, required this.toTaskId});
  final String fromTaskId;
  final String toTaskId;
}

/// Everything the painter needs, computed without touching a canvas.
class TimelineLayout {
  const TimelineLayout({
    required this.bars,
    required this.milestones,
    required this.links,
    required this.rangeStart,
    required this.rangeEnd,
    required this.undated,
  });

  final List<TimelineBar> bars;
  final List<TimelineMilestone> milestones;
  final List<TimelineLink> links;

  /// The window the chart covers, padded so nothing sits flush against an edge.
  final DateTime rangeStart;
  final DateTime rangeEnd;

  /// Tasks nobody dated. They are listed beside the chart for the user to place, never
  /// given a guessed position on it.
  final List<NoteTask> undated;

  bool get isEmpty => bars.isEmpty && milestones.isEmpty;

  int get totalDays => rangeEnd.difference(rangeStart).inDays + 1;

  int get rowCount => bars.isEmpty
      ? 0
      : bars.map((b) => b.row).reduce((a, b) => a > b ? a : b) + 1;

  /// Horizontal position of [date] as a fraction of the visible range.
  double fractionFor(DateTime date) {
    if (totalDays <= 1) return 0;
    final offset = date.difference(rangeStart).inDays;
    return (offset / (totalDays - 1)).clamp(0.0, 1.0);
  }

  /// How many bars carry a date the model derived rather than heard. Surfaced so the
  /// chart can say so rather than letting the reader assume everything was spoken.
  int get inferredCount =>
      bars.where((b) => b.basis == DateBasis.inferred).length;
}

/// Turns a note into a timeline.
///
/// Pure and synchronous: every decision about what appears where — and what deliberately
/// does not appear — is testable without a canvas.
class TimelinePlanner {
  const TimelinePlanner({this.padDays = 2, this.defaultDurationDays = 1});

  /// Breathing room at each end so a bar never sits flush against the edge.
  final int padDays;

  /// A task with a due date but no start is drawn as a marker on its due date rather
  /// than a bar of invented length.
  final int defaultDurationDays;

  TimelineLayout plan(NoteDocument note, {DateTime? today}) {
    final bars = <TimelineBar>[];
    final dates = <DateTime>[];

    // Only tasks the note actually dates. Placing an undated task would be inventing
    // the one thing this whole design refuses to invent.
    final placeable = note.tasks.where((t) => t.isSchedulable).toList()
      ..sort(_byStartThenDue);

    for (var i = 0; i < placeable.length; i++) {
      final task = placeable[i];
      final due = _parse(task.dueDate);
      if (due == null) continue;

      final start = _parse(task.startDate) ?? due;
      // A start after its due date is a model slip, not a zero-length task.
      final from = start.isAfter(due) ? due : start;
      final to =
          from == due ? due.add(Duration(days: defaultDurationDays - 1)) : due;

      bars.add(TimelineBar(
        taskId: task.id,
        title: task.title,
        start: from,
        end: to,
        basis: task.dateBasis,
        row: i,
        assigneeId: task.assigneeId,
        epic: task.epic,
      ));
      dates
        ..add(from)
        ..add(to);
    }

    final milestones = <TimelineMilestone>[];
    for (final anchor in note.timelineAnchors) {
      final date = _parse(anchor.date);
      if (date == null) continue;
      milestones.add(TimelineMilestone(label: anchor.label, date: date));
      dates.add(date);
    }

    // Only dependencies that were stated aloud, and only between bars both on the chart:
    // an arrow to something invisible is worse than no arrow.
    final placed = {for (final bar in bars) bar.taskId};
    final links = <TimelineLink>[
      for (final task in note.tasks)
        if (placed.contains(task.id))
          for (final dependency in task.dependsOn)
            if (placed.contains(dependency))
              TimelineLink(fromTaskId: dependency, toTaskId: task.id),
    ];

    final anchorDate = today ?? DateTime.now();
    final earliest = dates.isEmpty
        ? _atMidnight(anchorDate)
        : dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final latest = dates.isEmpty
        ? _atMidnight(anchorDate)
        : dates.reduce((a, b) => a.isAfter(b) ? a : b);

    return TimelineLayout(
      bars: bars,
      milestones: milestones,
      links: links,
      rangeStart: earliest.subtract(Duration(days: padDays)),
      rangeEnd: latest.add(Duration(days: padDays)),
      undated: note.needsDates,
    );
  }

  static int _byStartThenDue(NoteTask a, NoteTask b) {
    final aStart = _parse(a.startDate) ?? _parse(a.dueDate);
    final bStart = _parse(b.startDate) ?? _parse(b.dueDate);
    if (aStart == null || bStart == null) return 0;
    final byStart = aStart.compareTo(bStart);
    return byStart != 0 ? byStart : a.title.compareTo(b.title);
  }

  static DateTime? _parse(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final parsed = DateTime.tryParse(iso);
    return parsed == null ? null : _atMidnight(parsed);
  }

  static DateTime _atMidnight(DateTime d) => DateTime(d.year, d.month, d.day);
}
