// Dart mirror of `note-document/v1`. Hand-written rather than generated: the core package
// stays dependency-free and codegen-free so it builds in CI in seconds, and
// `test/schema_sync_test.dart` round-trips a fixture through both the validator and these
// classes so the two representations cannot drift.

// Where an extracted item came from. Required on every item — this is the anti-fabrication
/// mechanism, and it is what lets the UI jump to the moment in the audio.
class SourceRef {
  const SourceRef({this.startMs, this.endMs, required this.quote});

  /// Offset into the recording. Null only when the transcript carried no timestamps.
  final int? startMs;
  final int? endMs;

  /// A verbatim span of the transcript justifying the item. Verified after parsing by
  /// [QuoteVerifier]; items whose quote does not appear in the transcript are flagged.
  final String quote;

  factory SourceRef.fromJson(Map<String, dynamic> j) => SourceRef(
        startMs: j['startMs'] as int?,
        endMs: j['endMs'] as int?,
        quote: j['quote'] as String? ?? '',
      );

  Map<String, dynamic> toJson() =>
      {'startMs': startMs, 'endMs': endMs, 'quote': quote};
}

enum RecordingType {
  meeting,
  standup,
  interview,
  lecture,
  voiceMemo,
  call,
  other
}

enum ExtractionConfidence { high, medium, low }

enum TaskStatus { todo, inProgress, blocked, done }

enum TaskPriority { low, medium, high, critical }

enum EstimateUnit { hours, days, weeks, points }

/// Whether a task's dates were spoken, derived, or never discussed.
///
/// The most important enum in the app. A model asked only for a due date will manufacture
/// plausible dates for everything; making it declare the *kind* of date it holds is what
/// keeps the timeline honest. The UI renders the three cases differently and never
/// silently promotes one to another.
enum DateBasis {
  /// A concrete date or weekday was spoken.
  explicit,

  /// Resolved from relative language ("end of next sprint") against the recording date.
  inferred,

  /// No timing was discussed. Both date fields are null.
  absent,
}

class Estimate {
  const Estimate({required this.value, required this.unit});
  final num value;
  final EstimateUnit unit;

  factory Estimate.fromJson(Map<String, dynamic> j) => Estimate(
        value: j['value'] as num? ?? 0,
        unit: _enumFrom(EstimateUnit.values, j['unit'], EstimateUnit.days),
      );

  Map<String, dynamic> toJson() => {'value': value, 'unit': _wire(unit.name)};
}

class Participant {
  const Participant({
    required this.id,
    required this.displayName,
    this.aliases = const [],
    this.role,
  });

  final String id;
  final String displayName;

  /// Other forms heard in the audio: nicknames, diarization labels, STT mishearings.
  final List<String> aliases;
  final String? role;

  factory Participant.fromJson(Map<String, dynamic> j) => Participant(
        id: j['id'] as String? ?? '',
        displayName: j['displayName'] as String? ?? '',
        aliases: _stringList(j['aliases']),
        role: j['role'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'aliases': aliases,
        'role': role,
      };
}

class NoteSection {
  const NoteSection({
    required this.heading,
    required this.bullets,
    required this.sourceRef,
  });

  final String heading;
  final List<String> bullets;
  final SourceRef sourceRef;

  factory NoteSection.fromJson(Map<String, dynamic> j) => NoteSection(
        heading: j['heading'] as String? ?? '',
        bullets: _stringList(j['bullets']),
        sourceRef: SourceRef.fromJson(_obj(j['sourceRef'])),
      );

  Map<String, dynamic> toJson() => {
        'heading': heading,
        'bullets': bullets,
        'sourceRef': sourceRef.toJson(),
      };
}

class Decision {
  const Decision({
    required this.id,
    required this.statement,
    this.rationale,
    this.decidedBy,
    required this.sourceRef,
  });

  final String id;
  final String statement;
  final String? rationale;

  /// A [Participant.id], or null when the decision is unattributable.
  final String? decidedBy;
  final SourceRef sourceRef;

  factory Decision.fromJson(Map<String, dynamic> j) => Decision(
        id: j['id'] as String? ?? '',
        statement: j['statement'] as String? ?? '',
        rationale: j['rationale'] as String?,
        decidedBy: j['decidedBy'] as String?,
        sourceRef: SourceRef.fromJson(_obj(j['sourceRef'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'statement': statement,
        'rationale': rationale,
        'decidedBy': decidedBy,
        'sourceRef': sourceRef.toJson(),
      };
}

class OpenQuestion {
  const OpenQuestion({
    required this.id,
    required this.question,
    this.raisedBy,
    required this.sourceRef,
  });

  final String id;
  final String question;
  final String? raisedBy;
  final SourceRef sourceRef;

  factory OpenQuestion.fromJson(Map<String, dynamic> j) => OpenQuestion(
        id: j['id'] as String? ?? '',
        question: j['question'] as String? ?? '',
        raisedBy: j['raisedBy'] as String?,
        sourceRef: SourceRef.fromJson(_obj(j['sourceRef'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        'raisedBy': raisedBy,
        'sourceRef': sourceRef.toJson(),
      };
}

class Risk {
  const Risk({
    required this.id,
    required this.description,
    required this.severity,
    required this.sourceRef,
  });

  final String id;
  final String description;
  final RiskSeverity severity;
  final SourceRef sourceRef;

  factory Risk.fromJson(Map<String, dynamic> j) => Risk(
        id: j['id'] as String? ?? '',
        description: j['description'] as String? ?? '',
        severity:
            _enumFrom(RiskSeverity.values, j['severity'], RiskSeverity.medium),
        sourceRef: SourceRef.fromJson(_obj(j['sourceRef'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        'severity': severity.name,
        'sourceRef': sourceRef.toJson(),
      };
}

enum RiskSeverity { low, medium, high }

class TimelineAnchor {
  const TimelineAnchor({
    required this.label,
    required this.date,
    required this.sourceRef,
  });

  final String label;

  /// ISO-8601 date. Rendered as a milestone marker on the timeline.
  final String date;
  final SourceRef sourceRef;

  factory TimelineAnchor.fromJson(Map<String, dynamic> j) => TimelineAnchor(
        label: j['label'] as String? ?? '',
        date: j['date'] as String? ?? '',
        sourceRef: SourceRef.fromJson(_obj(j['sourceRef'])),
      );

  Map<String, dynamic> toJson() =>
      {'label': label, 'date': date, 'sourceRef': sourceRef.toJson()};
}

class NoteTask {
  const NoteTask({
    required this.id,
    required this.title,
    this.detail,
    this.assigneeId,
    this.assigneeRaw,
    this.status = TaskStatus.todo,
    this.priority = TaskPriority.medium,
    this.estimate,
    this.startDate,
    this.dueDate,
    this.dateBasis = DateBasis.absent,
    this.dependsOn = const [],
    this.epic,
    required this.sourceRef,
  });

  final String id;
  final String title;
  final String? detail;

  /// A [Participant.id] when the owner resolves to a known participant.
  final String? assigneeId;

  /// The name as spoken, when it does not resolve to a participant.
  final String? assigneeRaw;

  final TaskStatus status;
  final TaskPriority priority;
  final Estimate? estimate;

  /// ISO-8601 dates, resolved against the recording date. Both null when
  /// [dateBasis] is [DateBasis.absent].
  final String? startDate;
  final String? dueDate;
  final DateBasis dateBasis;

  /// Other [NoteTask.id] values. Populated only for dependencies stated aloud.
  final List<String> dependsOn;
  final String? epic;
  final SourceRef sourceRef;

  /// True when the task can be placed on the timeline at all.
  bool get isSchedulable => dateBasis != DateBasis.absent && dueDate != null;

  /// True when the task belongs in the board's "needs dates" tray.
  bool get needsDates => dateBasis == DateBasis.absent;

  bool get isOwned => assigneeId != null || assigneeRaw != null;

  factory NoteTask.fromJson(Map<String, dynamic> j) => NoteTask(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        detail: j['detail'] as String?,
        assigneeId: j['assigneeId'] as String?,
        assigneeRaw: j['assigneeRaw'] as String?,
        status: _enumFrom(TaskStatus.values, j['status'], TaskStatus.todo),
        priority:
            _enumFrom(TaskPriority.values, j['priority'], TaskPriority.medium),
        estimate: j['estimate'] == null
            ? null
            : Estimate.fromJson(_obj(j['estimate'])),
        startDate: j['startDate'] as String?,
        dueDate: j['dueDate'] as String?,
        dateBasis:
            _enumFrom(DateBasis.values, j['dateBasis'], DateBasis.absent),
        dependsOn: _stringList(j['dependsOn']),
        epic: j['epic'] as String?,
        sourceRef: SourceRef.fromJson(_obj(j['sourceRef'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'detail': detail,
        'assigneeId': assigneeId,
        'assigneeRaw': assigneeRaw,
        'status': _wire(status.name),
        'priority': priority.name,
        'estimate': estimate?.toJson(),
        'startDate': startDate,
        'dueDate': dueDate,
        'dateBasis': dateBasis.name,
        'dependsOn': dependsOn,
        'epic': epic,
        'sourceRef': sourceRef.toJson(),
      };

  NoteTask copyWith({
    String? title,
    Object? detail = _sentinel,
    TaskStatus? status,
    TaskPriority? priority,
    Object? startDate = _sentinel,
    Object? dueDate = _sentinel,
    DateBasis? dateBasis,
    Object? assigneeId = _sentinel,
    Object? assigneeRaw = _sentinel,
    Object? epic = _sentinel,
  }) =>
      NoteTask(
        id: id,
        title: title ?? this.title,
        detail: identical(detail, _sentinel) ? this.detail : detail as String?,
        assigneeId: identical(assigneeId, _sentinel)
            ? this.assigneeId
            : assigneeId as String?,
        assigneeRaw: identical(assigneeRaw, _sentinel)
            ? this.assigneeRaw
            : assigneeRaw as String?,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        estimate: estimate,
        startDate: identical(startDate, _sentinel)
            ? this.startDate
            : startDate as String?,
        dueDate:
            identical(dueDate, _sentinel) ? this.dueDate : dueDate as String?,
        dateBasis: dateBasis ?? this.dateBasis,
        dependsOn: dependsOn,
        epic: identical(epic, _sentinel) ? this.epic : epic as String?,
        sourceRef: sourceRef,
      );
}

const Object _sentinel = Object();

class NoteMeta {
  const NoteMeta({
    required this.title,
    required this.summary,
    required this.recordingType,
    required this.language,
    required this.extractionConfidence,
  });

  final String title;
  final String summary;
  final RecordingType recordingType;

  /// BCP-47 tag of the dominant spoken language.
  final String language;
  final ExtractionConfidence extractionConfidence;

  factory NoteMeta.fromJson(Map<String, dynamic> j) => NoteMeta(
        title: j['title'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
        recordingType: _enumFrom(
            RecordingType.values, j['recordingType'], RecordingType.other),
        language: j['language'] as String? ?? 'en-US',
        extractionConfidence: _enumFrom(
          ExtractionConfidence.values,
          j['extractionConfidence'],
          ExtractionConfidence.medium,
        ),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'summary': summary,
        'recordingType': _wire(recordingType.name),
        'language': language,
        'extractionConfidence': extractionConfidence.name,
      };
}

class NoteDocument {
  const NoteDocument({
    required this.meta,
    this.participants = const [],
    this.sections = const [],
    this.decisions = const [],
    this.openQuestions = const [],
    this.tasks = const [],
    this.risks = const [],
    this.timelineAnchors = const [],
  });

  final NoteMeta meta;
  final List<Participant> participants;
  final List<NoteSection> sections;
  final List<Decision> decisions;
  final List<OpenQuestion> openQuestions;
  final List<NoteTask> tasks;
  final List<Risk> risks;
  final List<TimelineAnchor> timelineAnchors;

  factory NoteDocument.fromJson(Map<String, dynamic> j) => NoteDocument(
        meta: NoteMeta.fromJson(_obj(j['meta'])),
        participants: _list(j['participants'], Participant.fromJson),
        sections: _list(j['sections'], NoteSection.fromJson),
        decisions: _list(j['decisions'], Decision.fromJson),
        openQuestions: _list(j['openQuestions'], OpenQuestion.fromJson),
        tasks: _list(j['tasks'], NoteTask.fromJson),
        risks: _list(j['risks'], Risk.fromJson),
        timelineAnchors: _list(j['timelineAnchors'], TimelineAnchor.fromJson),
      );

  Map<String, dynamic> toJson() => {
        'meta': meta.toJson(),
        'participants': participants.map((e) => e.toJson()).toList(),
        'sections': sections.map((e) => e.toJson()).toList(),
        'decisions': decisions.map((e) => e.toJson()).toList(),
        'openQuestions': openQuestions.map((e) => e.toJson()).toList(),
        'tasks': tasks.map((e) => e.toJson()).toList(),
        'risks': risks.map((e) => e.toJson()).toList(),
        'timelineAnchors': timelineAnchors.map((e) => e.toJson()).toList(),
      };

  /// Board columns, derived — not a second model call. See ARCHITECTURE.md §3.
  Map<TaskStatus, List<NoteTask>> get board => {
        for (final s in TaskStatus.values)
          s: tasks.where((t) => t.status == s).toList(growable: false),
      };

  /// Tasks the timeline can place, and the ones the user must date themselves.
  List<NoteTask> get schedulable =>
      tasks.where((t) => t.isSchedulable).toList();
  List<NoteTask> get needsDates => tasks.where((t) => t.needsDates).toList();

  // ---------------------------------------------------------------------------
  // Board edits.
  //
  // Each returns a new document that is still schema-valid, because the edited document
  // is what gets written back to storage and re-read later. Order within the tasks array
  // is the board's column order — no extra field is needed, since JSON arrays preserve
  // order.
  // ---------------------------------------------------------------------------

  /// Replaces a task by id, or appends it when it is new.
  NoteDocument withTask(NoteTask task) {
    final index = tasks.indexWhere((t) => t.id == task.id);
    final next = [...tasks];
    if (index >= 0) {
      next[index] = task;
    } else {
      next.add(task);
    }
    return _copyWithTasks(next);
  }

  NoteDocument withoutTask(String id) =>
      _copyWithTasks(tasks.where((t) => t.id != id).toList());

  /// Moves a task to another column.
  ///
  /// Dragging a card is not a claim about when the work is due, so dates and their basis
  /// are untouched — only the status changes.
  NoteDocument movedTask(String id, TaskStatus status) {
    final index = tasks.indexWhere((t) => t.id == id);
    if (index < 0) return this;
    final next = [...tasks];
    next[index] = next[index].copyWith(status: status);
    return _copyWithTasks(next);
  }

  /// Moves a task to [status] and places it at [position] within that column.
  ///
  /// Position is expressed within the column the user sees, then translated into an
  /// index in the flat array, so a reorder in one column never disturbs another.
  NoteDocument reorderedTask(String id, TaskStatus status, int position) {
    final moving = tasks.where((t) => t.id == id).firstOrNull;
    if (moving == null) return this;

    final remaining = tasks.where((t) => t.id != id).toList();
    final column = remaining.where((t) => t.status == status).toList();
    final clamped = position < 0
        ? 0
        : position > column.length
            ? column.length
            : position;

    // The flat index of the card currently in that slot; append when the card lands at
    // the end of its column.
    final anchor = clamped < column.length ? column[clamped] : null;
    final insertAt =
        anchor == null ? remaining.length : remaining.indexOf(anchor);

    return _copyWithTasks(
      [...remaining]..insert(insertAt, moving.copyWith(status: status)),
    );
  }

  /// Tasks matching every supplied filter. An unset filter matches everything.
  List<NoteTask> filteredTasks({
    String? assigneeId,
    TaskPriority? priority,
    bool unassignedOnly = false,
  }) =>
      tasks.where((task) {
        if (unassignedOnly && task.isOwned) return false;
        if (assigneeId != null && task.assigneeId != assigneeId) return false;
        if (priority != null && task.priority != priority) return false;
        return true;
      }).toList();

  /// Everyone who owns at least one task, for the filter bar.
  List<Participant> get assignees => participants
      .where((p) => tasks.any((t) => t.assigneeId == p.id))
      .toList();

  NoteDocument _copyWithTasks(List<NoteTask> next) => NoteDocument(
        meta: meta,
        participants: participants,
        sections: sections,
        decisions: decisions,
        openQuestions: openQuestions,
        tasks: next,
        risks: risks,
        timelineAnchors: timelineAnchors,
      );
}

// ---------------------------------------------------------------------------
// Wire-format helpers. The schema uses snake_case for multi-word enum values
// (`in_progress`, `voice_memo`); Dart uses lowerCamelCase.
// ---------------------------------------------------------------------------

String _wire(String dartName) => dartName.replaceAllMapped(
    RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

T _enumFrom<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  for (final v in values) {
    if (v.name == raw || _wire(v.name) == raw) return v;
  }
  return fallback;
}

Map<String, dynamic> _obj(Object? v) =>
    v is Map<String, dynamic> ? v : <String, dynamic>{};

List<String> _stringList(Object? v) =>
    v is List ? v.whereType<String>().toList() : const [];

List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) from) => v is List
    ? v.whereType<Map<String, dynamic>>().map(from).toList()
    : const [];
