import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import 'board_controller.dart';

/// Opens the editor for [task], or for a new task when it is null.
Future<void> openTaskEditor(
  BuildContext context,
  WidgetRef ref, {
  required String recordingId,
  required NoteDocument note,
  NoteTask? task,
  TaskStatus initialStatus = TaskStatus.todo,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: TaskEditor(
          recordingId: recordingId,
          note: note,
          task: task,
          initialStatus: initialStatus,
        ),
      ),
    );

/// Edit one action item, or write a new one.
///
/// Setting a date here is the user speaking for themselves, so it is recorded as
/// `explicit` — a date the user typed is known, not inferred. The model's own uncertainty
/// is never overwritten silently in the other direction.
class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({
    super.key,
    required this.recordingId,
    required this.note,
    this.task,
    this.initialStatus = TaskStatus.todo,
  });

  final String recordingId;
  final NoteDocument note;
  final NoteTask? task;
  final TaskStatus initialStatus;

  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.task?.title ?? '');
  late TaskStatus _status = widget.task?.status ?? widget.initialStatus;
  late TaskPriority _priority = widget.task?.priority ?? TaskPriority.medium;
  late String? _assigneeId = widget.task?.assigneeId;
  late String? _dueDate = widget.task?.dueDate;
  late DateBasis _dateBasis = widget.task?.dateBasis ?? DateBasis.absent;

  bool get _isNew => widget.task == null;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;

    final base = widget.task ?? manualTask(title: title, status: _status);
    final updated = base.copyWith(
      title: title,
      status: _status,
      priority: _priority,
      assigneeId: _assigneeId,
      dueDate: _dueDate,
      dateBasis: _dateBasis,
    );

    await ref
        .read(boardEditorProvider)
        .upsert(widget.recordingId, widget.note, updated);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_dueDate ?? '') ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _dueDate = '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
      // A date the user typed is known, not inferred.
      _dateBasis = DateBasis.explicit;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_isNew ? 'New task' : 'Edit task',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                if (!_isNew)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () async {
                      await ref.read(boardEditorProvider).remove(
                          widget.recordingId, widget.note, widget.task!.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              autofocus: _isNew,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What needs doing',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            _Label('Column'),
            Wrap(
              spacing: 8,
              children: [
                for (final status in TaskStatus.values)
                  ChoiceChip(
                    label: Text(_statusLabel(status)),
                    selected: _status == status,
                    onSelected: (_) => setState(() => _status = status),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _Label('Priority'),
            Wrap(
              spacing: 8,
              children: [
                for (final priority in TaskPriority.values)
                  ChoiceChip(
                    label: Text(priority.name),
                    selected: _priority == priority,
                    onSelected: (_) => setState(() => _priority = priority),
                  ),
              ],
            ),
            if (widget.note.participants.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Label('Owner'),
              Wrap(
                spacing: 8,
                children: [
                  for (final person in widget.note.participants)
                    ChoiceChip(
                      label: Text(person.displayName),
                      selected: _assigneeId == person.id,
                      onSelected: (on) =>
                          setState(() => _assigneeId = on ? person.id : null),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            _Label('Due'),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event, size: 18),
                  label: Text(_dueDate ?? 'No date discussed'),
                ),
                if (_dueDate != null)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    tooltip: 'Clear the date',
                    onPressed: () => setState(() {
                      _dueDate = null;
                      _dateBasis = DateBasis.absent;
                    }),
                  ),
              ],
            ),
            if (_dateBasis == DateBasis.inferred)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'This date was inferred from the recording, not stated outright. '
                  'Setting it here confirms it.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.tertiary),
                ),
              ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(TaskStatus status) => switch (status) {
        TaskStatus.todo => 'To do',
        TaskStatus.inProgress => 'In progress',
        TaskStatus.blocked => 'Blocked',
        TaskStatus.done => 'Done',
      };
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}
