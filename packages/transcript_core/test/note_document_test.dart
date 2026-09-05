import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  test('round-trips through JSON without losing anything', () {
    final original = validNoteJson();
    final encoded = NoteDocument.fromJson(original).toJson();
    expect(encoded, equals(original));
  });

  test('the re-encoded document still validates against the schema', () {
    final doc = NoteDocument.fromJson(validNoteJson());
    expect(SchemaValidator(noteDocumentSchema).validate(doc.toJson()), isEmpty,
        reason:
            'edits made in the app must stay schema-valid on the way back out');
  });

  test('snake_case wire values map to camelCase enums both ways', () {
    final json = validNoteJson();
    ((json['tasks'] as List<dynamic>).first as Map<String, dynamic>)['status'] =
        'in_progress';
    (json['meta'] as Map<String, dynamic>)['recordingType'] = 'voice_memo';

    final doc = NoteDocument.fromJson(json);
    expect(doc.tasks.single.status, TaskStatus.inProgress);
    expect(doc.meta.recordingType, RecordingType.voiceMemo);
    expect(doc.toJson(), equals(json));
  });

  test('an unrecognised enum value falls back rather than throwing', () {
    // A model that invents a status must not crash the note; the validator is what
    // rejects it, and by then the user still has their transcript.
    final json = validNoteJson();
    ((json['tasks'] as List<dynamic>).first
        as Map<String, dynamic>)['priority'] = 'urgent';
    expect(
        NoteDocument.fromJson(json).tasks.single.priority, TaskPriority.medium);
  });

  group('derived views — no second model call', () {
    NoteDocument withTasks(List<Map<String, dynamic>> tasks) {
      final json = validNoteJson()..['tasks'] = tasks;
      return NoteDocument.fromJson(json);
    }

    Map<String, dynamic> task(
      String id, {
      String status = 'todo',
      String dateBasis = 'absent',
      String? dueDate,
    }) =>
        {
          'id': id,
          'title': id,
          'detail': null,
          'assigneeId': null,
          'assigneeRaw': null,
          'status': status,
          'priority': 'medium',
          'estimate': null,
          'startDate': null,
          'dueDate': dueDate,
          'dateBasis': dateBasis,
          'dependsOn': <String>[],
          'epic': null,
          'sourceRef': {'startMs': 0, 'endMs': 1, 'quote': 'q'},
        };

    test('the board is a group-by over status', () {
      final doc = withTasks([
        task('a'),
        task('b', status: 'in_progress'),
        task('c', status: 'in_progress'),
        task('d', status: 'done'),
      ]);

      expect(doc.board[TaskStatus.todo], hasLength(1));
      expect(doc.board[TaskStatus.inProgress], hasLength(2));
      expect(doc.board[TaskStatus.blocked], isEmpty);
      expect(doc.board.keys, containsAll(TaskStatus.values),
          reason:
              'every column exists even when empty, so the board renders stably');
    });

    test('only dated tasks reach the timeline; the rest go to the tray', () {
      final doc = withTasks([
        task('explicit', dateBasis: 'explicit', dueDate: '2026-09-18'),
        task('inferred', dateBasis: 'inferred', dueDate: '2026-09-30'),
        task('absent'),
      ]);

      expect(doc.schedulable.map((t) => t.id), ['explicit', 'inferred']);
      expect(doc.needsDates.map((t) => t.id), ['absent'],
          reason: 'an undated task is never placed on the chart by guesswork');
    });

    test('a dateBasis without a date is not schedulable', () {
      // Defends against a model that marks a basis but leaves the field null.
      final doc = withTasks([task('half', dateBasis: 'inferred')]);
      expect(doc.schedulable, isEmpty);
    });
  });

  test('dragging a bar onto the timeline promotes the task to a real date', () {
    final doc = NoteDocument.fromJson(validNoteJson());
    final undated = doc.tasks.single.copyWith(
      dueDate: null,
      dateBasis: DateBasis.absent,
    );
    expect(undated.needsDates, isTrue);

    final placed =
        undated.copyWith(dueDate: '2026-09-20', dateBasis: DateBasis.explicit);
    expect(placed.isSchedulable, isTrue);
    expect(placed.title, undated.title,
        reason: 'copyWith preserves everything else');
  });

  test('copyWith can clear a nullable field as well as set one', () {
    final task = NoteDocument.fromJson(validNoteJson()).tasks.single;
    expect(task.assigneeId, isNotNull);
    expect(task.copyWith(assigneeId: null).assigneeId, isNull);
    expect(task.copyWith().assigneeId, isNotNull,
        reason: 'omitting a field must not clear it');
  });

  test('ownership requires someone to have actually taken the work', () {
    final json = validNoteJson();
    final t = (json['tasks'] as List<dynamic>).first as Map<String, dynamic>;
    t['assigneeId'] = null;
    t['assigneeRaw'] = null;
    expect(NoteDocument.fromJson(json).tasks.single.isOwned, isFalse);
  });
}
