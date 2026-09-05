import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/database.dart' as db;
import '../recording/recording_controller.dart';
import '../settings/settings_screen.dart';
import 'note_screen.dart';
import 'record_screen.dart';

/// Everything recorded on this device. Local only — there is no account and no sync.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordings = ref.watch(recordingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'AI providers',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: recordings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not open the library.\n$e')),
        data: (items) => items.isEmpty
            ? const _EmptyLibrary()
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) => _RecordingTile(recording: items[i]),
              ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none,
                size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text('Nothing recorded yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Recordings stay on this device.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingTile extends ConsumerWidget {
  const _RecordingTile({required this.recording});

  final db.Recording recording;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final structured = recording.noteJson != null;
    final duration = Duration(milliseconds: recording.durationMs);

    return Dismissible(
      key: ValueKey(recording.id),
      direction: DismissDirection.endToStart,
      background: ColoredBox(
        color: theme.colorScheme.errorContainer,
        child: const Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.only(right: 20),
            child: Icon(Icons.delete_outline),
          ),
        ),
      ),
      confirmDismiss: (_) async => await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Delete this recording?'),
              content: const Text(
                  'The audio and its notes are removed from this device. This cannot '
                  'be undone.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Keep'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ) ??
          false,
      onDismissed: (_) =>
          ref.read(repositoryProvider).delete(recording.id),
      child: ListTile(
        title: Text(
          recording.title.isEmpty ? 'Untitled recording' : recording.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${DateFormat.yMMMd().add_jm().format(recording.startedAt)} · '
          '${formatDuration(duration)}',
        ),
        leading: Icon(
          structured ? Icons.notes : Icons.hourglass_empty,
          color: structured
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NoteScreen(recordingId: recording.id),
          ),
        ),
      ),
    );
  }
}
