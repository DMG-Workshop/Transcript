import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import 'board_controller.dart';
import 'task_editor.dart';

/// A Kanban board over the note's action items.
///
/// The columns are `groupBy(status)` over the same tasks the notes tab shows — no second
/// model call, no separate board document. Dragging a card writes the whole note back
/// immediately, so an edit cannot be lost between screens.
class BoardView extends ConsumerWidget {
  const BoardView({super.key, required this.recordingId, required this.note});

  final String recordingId;
  final NoteDocument note;

  static const List<TaskStatus> columnOrder = [
    TaskStatus.todo,
    TaskStatus.inProgress,
    TaskStatus.blocked,
    TaskStatus.done,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(boardFilterProvider(recordingId));
    final visible = note
        .filteredTasks(
          assigneeId: filter.assigneeId,
          priority: filter.priority,
          unassignedOnly: filter.unassignedOnly,
        )
        .map((t) => t.id)
        .toSet();

    if (note.tasks.isEmpty) {
      return _EmptyBoard(recordingId: recordingId, note: note);
    }

    return Column(
      children: [
        _FilterBar(recordingId: recordingId, note: note),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            children: [
              for (final status in columnOrder)
                _Column(
                  recordingId: recordingId,
                  note: note,
                  status: status,
                  tasks: note.board[status]!
                      .where((t) => visible.contains(t.id))
                      .toList(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Column extends ConsumerWidget {
  const _Column({
    required this.recordingId,
    required this.note,
    required this.status,
    required this.tasks,
  });

  final String recordingId;
  final NoteDocument note;
  final TaskStatus status;
  final List<NoteTask> tasks;

  static const double width = 280;

  String get _label => switch (status) {
        TaskStatus.todo => 'To do',
        TaskStatus.inProgress => 'In progress',
        TaskStatus.blocked => 'Blocked',
        TaskStatus.done => 'Done',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return DragTarget<NoteTask>(
      onWillAcceptWithDetails: (details) => details.data.status != status,
      onAcceptWithDetails: (details) => ref
          .read(boardEditorProvider)
          .move(recordingId, note, details.data.id, status),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return Container(
          width: width,
          margin: const EdgeInsets.only(right: 12),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: hovering
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
                child: Row(
                  children: [
                    Text(_label, style: theme.textTheme.titleSmall),
                    const SizedBox(width: 8),
                    Text(
                      '${tasks.length}',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add, size: 18),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Add a task to $_label',
                      onPressed: () => openTaskEditor(
                        context,
                        ref,
                        recordingId: recordingId,
                        note: note,
                        initialStatus: status,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? _EmptyColumn(hovering: hovering)
                    : ListView.builder(
                        itemCount: tasks.length,
                        itemBuilder: (context, i) => _DraggableCard(
                          recordingId: recordingId,
                          note: note,
                          task: tasks[i],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyColumn extends StatelessWidget {
  const _EmptyColumn({required this.hovering});

  final bool hovering;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        hovering ? 'Drop here' : 'Nothing here',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _DraggableCard extends ConsumerWidget {
  const _DraggableCard({
    required this.recordingId,
    required this.note,
    required this.task,
  });

  final String recordingId;
  final NoteDocument note;
  final NoteTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = TaskCard(
      task: task,
      participants: note.participants,
      onTap: () => openTaskEditor(
        context,
        ref,
        recordingId: recordingId,
        note: note,
        task: task,
      ),
    );

    return LongPressDraggable<NoteTask>(
      data: task,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(width: _Column.width - 16, child: card),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }
}

/// One action item.
class TaskCard extends ConsumerWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.participants,
    this.onTap,
  });

  final NoteTask task;
  final List<Participant> participants;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final owner = _ownerName();

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.title, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (owner != null) _Meta(icon: Icons.person_outline, label: owner),
                  if (task.priority != TaskPriority.medium)
                    _Meta(
                      icon: Icons.flag_outlined,
                      label: task.priority.name,
                      tone: task.priority == TaskPriority.critical
                          ? theme.colorScheme.error
                          : null,
                    ),
                  _DateMeta(task: task),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _ownerName() {
    if (task.assigneeRaw != null) return task.assigneeRaw;
    if (task.assigneeId == null) return null;
    for (final p in participants) {
      if (p.id == task.assigneeId) return p.displayName;
    }
    return null;
  }
}

/// The three date states, rendered so they can never be mistaken for one another.
class _DateMeta extends StatelessWidget {
  const _DateMeta({required this.task});

  final NoteTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (task.dateBasis) {
      DateBasis.explicit => _Meta(
          icon: Icons.event_available,
          label: task.dueDate ?? '',
          tone: theme.colorScheme.primary,
        ),
      DateBasis.inferred => _Meta(
          icon: Icons.event_note,
          label: '${task.dueDate ?? ''} · inferred',
          tone: theme.colorScheme.tertiary,
        ),
      DateBasis.absent =>
        const _Meta(icon: Icons.event_busy, label: 'no date discussed'),
    };
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.label, this.tone});

  final IconData icon;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        // Flexible with an ellipsis: a long label — an inferred date carries its own
        // qualifier — must not overflow the card it sits in.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.recordingId, required this.note});

  final String recordingId;
  final NoteDocument note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(boardFilterProvider(recordingId));
    final controller = ref.read(boardFilterProvider(recordingId).notifier);
    final undated = note.needsDates.length;

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          for (final person in note.assignees)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(person.displayName),
                selected: filter.assigneeId == person.id,
                onSelected: (on) => controller.state =
                    filter.copyWith(assigneeId: on ? person.id : null),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('Unassigned'),
              selected: filter.unassignedOnly,
              onSelected: (on) =>
                  controller.state = filter.copyWith(unassignedOnly: on),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('High priority'),
              selected: filter.priority == TaskPriority.high,
              onSelected: (on) => controller.state =
                  filter.copyWith(priority: on ? TaskPriority.high : null),
            ),
          ),
          if (undated > 0)
            Chip(
              avatar: const Icon(Icons.event_busy, size: 14),
              label: Text('$undated need dates'),
            ),
        ],
      ),
    );
  }
}

class _EmptyBoard extends ConsumerWidget {
  const _EmptyBoard({required this.recordingId, required this.note});

  final String recordingId;
  final NoteDocument note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No action items came out of this recording.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => openTaskEditor(
                context,
                ref,
                recordingId: recordingId,
                note: note,
              ),
              child: const Text('Add one yourself'),
            ),
          ],
        ),
      ),
    );
  }
}
