import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  Map<String, dynamic> task(
    String id, {
    String status = 'todo',
    String? assigneeId,
    String priority = 'medium',
    String dateBasis = 'absent',
    String? dueDate,
  }) =>
      {
        'id': id,
        'title': 'Task $id',
        'detail': null,
        'assigneeId': assigneeId,
        'assigneeRaw': null,
        'status': status,
        'priority': priority,
        'estimate': null,
        'startDate': null,
        'dueDate': dueDate,
        'dateBasis': dateBasis,
        'dependsOn': <String>[],
        'epic': null,
        'sourceRef': {
          'startMs': 0,
          'endMs': 1,
          'quote': 'a quote from the meeting'
        },
      };

  NoteDocument docWith(List<Map<String, dynamic>> tasks) =>
      NoteDocument.fromJson(validNoteJson()..['tasks'] = tasks);

  final validator = SchemaValidator(noteDocumentSchema);

  group('moving cards', () {
    test('dragging to another column changes only the status', () {
      final doc =
          docWith([task('a', dateBasis: 'explicit', dueDate: '2026-09-18')]);
      final moved = doc.movedTask('a', TaskStatus.done);

      final after = moved.tasks.single;
      expect(after.status, TaskStatus.done);
      expect(after.dueDate, '2026-09-18');
      expect(after.dateBasis, DateBasis.explicit,
          reason: 'moving a card says nothing about when the work is due');
    });

    test('moving a task that no longer exists is a no-op, not a crash', () {
      final doc = docWith([task('a')]);
      expect(doc.movedTask('gone', TaskStatus.done).tasks, hasLength(1));
    });

    test('the edited document is still schema-valid', () {
      final doc = docWith([task('a')]);
      final moved = doc.movedTask('a', TaskStatus.inProgress);
      expect(validator.validate(moved.toJson()), isEmpty,
          reason: 'the edited document is what gets written back and re-read');
    });
  });

  group('reordering within a column', () {
    test('moves a card to the requested position', () {
      final doc = docWith([task('a'), task('b'), task('c')]);
      final reordered = doc.reorderedTask('c', TaskStatus.todo, 0);

      expect(
          reordered.board[TaskStatus.todo]!.map((t) => t.id), ['c', 'a', 'b']);
    });

    test('a position past the end appends', () {
      final doc = docWith([task('a'), task('b')]);
      final reordered = doc.reorderedTask('a', TaskStatus.todo, 99);
      expect(reordered.board[TaskStatus.todo]!.map((t) => t.id), ['b', 'a']);
    });

    test('reordering one column leaves the others untouched', () {
      final doc = docWith([
        task('a'),
        task('x', status: 'in_progress'),
        task('b'),
        task('y', status: 'in_progress'),
      ]);

      final reordered = doc.reorderedTask('b', TaskStatus.todo, 0);
      expect(reordered.board[TaskStatus.todo]!.map((t) => t.id), ['b', 'a']);
      expect(
          reordered.board[TaskStatus.inProgress]!.map((t) => t.id), ['x', 'y'],
          reason: 'a drag in one column must not disturb another');
    });

    test('dropping into a different column both moves and places', () {
      final doc = docWith([
        task('a'),
        task('b'),
        task('x', status: 'done'),
      ]);

      final reordered = doc.reorderedTask('a', TaskStatus.done, 0);
      expect(reordered.board[TaskStatus.done]!.map((t) => t.id), ['a', 'x']);
      expect(reordered.board[TaskStatus.todo]!.map((t) => t.id), ['b']);
    });

    test('no task is lost or duplicated by a reorder', () {
      final doc = docWith([for (final id in 'abcdef'.split('')) task(id)]);
      final reordered = doc.reorderedTask('d', TaskStatus.blocked, 0);

      expect(reordered.tasks.map((t) => t.id).toSet(),
          doc.tasks.map((t) => t.id).toSet());
      expect(reordered.tasks, hasLength(6));
    });
  });

  group('adding and removing', () {
    test('a manually created task joins the board', () {
      // Every extraction misses something; the board is useless if it cannot be
      // corrected by hand.
      final doc = docWith([task('a')]);
      final added = doc.withTask(NoteTask.fromJson(task('manual')));

      expect(added.tasks, hasLength(2));
      expect(validator.validate(added.toJson()), isEmpty);
    });

    test('editing a task replaces it in place rather than appending', () {
      final doc = docWith([task('a'), task('b')]);
      final edited = doc.withTask(doc.tasks.first.copyWith(title: 'Renamed'));

      expect(edited.tasks, hasLength(2));
      expect(edited.tasks.first.title, 'Renamed');
      expect(edited.tasks.map((t) => t.id), ['a', 'b'],
          reason: 'order is preserved');
    });

    test('removing a task takes only that one', () {
      final doc = docWith([task('a'), task('b')]);
      expect(doc.withoutTask('a').tasks.map((t) => t.id), ['b']);
    });
  });

  group('filters', () {
    final doc = docWith([
      task('a', assigneeId: 'p_priya', priority: 'high'),
      task('b', assigneeId: 'p_priya'),
      task('c', priority: 'high'),
    ]);

    test('by assignee', () {
      expect(doc.filteredTasks(assigneeId: 'p_priya').map((t) => t.id),
          ['a', 'b']);
    });

    test('by priority', () {
      expect(doc.filteredTasks(priority: TaskPriority.high).map((t) => t.id),
          ['a', 'c']);
    });

    test('filters combine', () {
      expect(
        doc
            .filteredTasks(assigneeId: 'p_priya', priority: TaskPriority.high)
            .map((t) => t.id),
        ['a'],
      );
    });

    test('unowned work can be surfaced on its own', () {
      // "Somebody should look at that" is the most commonly lost commitment in a
      // meeting, so it has to be findable.
      expect(doc.filteredTasks(unassignedOnly: true).map((t) => t.id), ['c']);
    });

    test('no filter returns everything', () {
      expect(doc.filteredTasks(), hasLength(3));
    });

    test('the assignee list covers only people who actually own work', () {
      expect(doc.assignees.map((p) => p.id), ['p_priya']);
    });
  });

  test('the board keeps every column, including the empty ones', () {
    final board = docWith([task('a')]).board;
    expect(board.keys, containsAll(TaskStatus.values),
        reason: 'a column that vanishes when emptied cannot be dropped into');
    expect(board[TaskStatus.done], isEmpty);
  });
}
