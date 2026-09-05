import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import '../data/repository.dart';
import '../recording/recording_controller.dart';

/// Which cards the board is showing.
class BoardFilter {
  const BoardFilter({this.assigneeId, this.priority, this.unassignedOnly = false});

  final String? assigneeId;
  final TaskPriority? priority;
  final bool unassignedOnly;

  bool get isActive =>
      assigneeId != null || priority != null || unassignedOnly;

  BoardFilter copyWith({
    Object? assigneeId = _unset,
    Object? priority = _unset,
    bool? unassignedOnly,
  }) =>
      BoardFilter(
        assigneeId:
            identical(assigneeId, _unset) ? this.assigneeId : assigneeId as String?,
        priority: identical(priority, _unset)
            ? this.priority
            : priority as TaskPriority?,
        unassignedOnly: unassignedOnly ?? this.unassignedOnly,
      );

  static const Object _unset = Object();
}

final boardFilterProvider =
    StateProvider.family<BoardFilter, String>((ref, _) => const BoardFilter());

/// Applies board edits and writes them straight back to storage.
///
/// There is no separate "save" — a card dragged to another column is persisted before
/// the animation finishes, because a board that silently loses an edit is worse than one
/// that cannot be edited at all.
class BoardEditor {
  const BoardEditor(this._repository);

  final RecordingRepository _repository;

  Future<void> move(String recordingId, NoteDocument doc, String taskId,
          TaskStatus status) =>
      _repository.updateNote(recordingId, doc.movedTask(taskId, status));

  Future<void> reorder(String recordingId, NoteDocument doc, String taskId,
          TaskStatus status, int position) =>
      _repository.updateNote(
          recordingId, doc.reorderedTask(taskId, status, position));

  Future<void> upsert(String recordingId, NoteDocument doc, NoteTask task) =>
      _repository.updateNote(recordingId, doc.withTask(task));

  Future<void> remove(String recordingId, NoteDocument doc, String taskId) =>
      _repository.updateNote(recordingId, doc.withoutTask(taskId));
}

final boardEditorProvider = Provider<BoardEditor>(
  (ref) => BoardEditor(ref.watch(repositoryProvider)),
);

/// A task the user created by hand.
///
/// Every extraction misses something, so the board has to be correctable. A manual task
/// carries no `sourceRef` quote it could honestly cite, so it gets an explicit marker
/// instead — never a fabricated one.
NoteTask manualTask({required String title, TaskStatus status = TaskStatus.todo}) =>
    NoteTask(
      id: 'manual_${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      status: status,
      sourceRef: const SourceRef(quote: manualQuoteMarker),
    );

/// Marks a task as hand-written rather than extracted. Short enough that the quote
/// verifier treats it as unverifiable rather than flagging it as a fabrication.
const String manualQuoteMarker = 'added by hand';

bool isManual(NoteTask task) => task.sourceRef.quote == manualQuoteMarker;
