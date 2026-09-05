import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import '../data/database.dart' as db;
import '../data/repository.dart';
import '../recording/recording_controller.dart';
import 'record_screen.dart';

/// One recording: its notes, its tasks, and the transcript underneath.
///
/// Three tabs rather than one scroll, because the three are read for different reasons —
/// the notes to catch up, the tasks to act, the transcript to check what was actually
/// said. Every item can be traced to the moment it came from.
class NoteScreen extends ConsumerWidget {
  const NoteScreen({super.key, required this.recordingId});

  final String recordingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordings = ref.watch(recordingsProvider);

    return recordings.when(
      loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
      data: (items) {
        final recording = items.where((r) => r.id == recordingId).firstOrNull;
        if (recording == null) {
          return const Scaffold(
            body: Center(child: Text('That recording is no longer here.')),
          );
        }
        return _NoteView(recording: recording);
      },
    );
  }
}

class _NoteView extends StatelessWidget {
  const _NoteView({required this.recording});

  final db.Recording recording;

  @override
  Widget build(BuildContext context) {
    final note = decodeNote(recording);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            recording.title.isEmpty ? 'Untitled recording' : recording.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          bottom: const TabBar(tabs: [
            Tab(text: 'Notes'),
            Tab(text: 'Actions'),
            Tab(text: 'Transcript'),
          ]),
        ),
        body: note == null
            ? const _NotStructuredYet()
            : TabBarView(children: [
                _NotesTab(note: note, recording: recording),
                _ActionsTab(note: note),
                _TranscriptTab(note: note),
              ]),
      ),
    );
  }
}

class _NotStructuredYet extends StatelessWidget {
  const _NotStructuredYet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_empty,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text('No notes for this recording',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'The audio and any transcript are still saved. You can write notes from '
              'it again with a different service.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotesTab extends StatelessWidget {
  const _NotesTab({required this.note, required this.recording});

  final NoteDocument note;
  final db.Recording recording;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        Text(note.meta.summary, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 8),
        if (note.meta.extractionConfidence != ExtractionConfidence.high)
          _Caveat(
            text: note.meta.extractionConfidence == ExtractionConfidence.low
                ? 'The audio was hard to make out, so these notes may be incomplete.'
                : 'Parts of the audio were unclear.',
          ),
        for (final section in note.sections) ...[
          const SizedBox(height: 24),
          Text(section.heading, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final bullet in section.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('·  ', style: theme.textTheme.bodyLarge),
                  Expanded(
                      child: Text(bullet, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
        if (note.decisions.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Decisions', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final decision in note.decisions)
            _Cited(
              quote: decision.sourceRef.quote,
              child: Text(decision.statement,
                  style: theme.textTheme.bodyMedium),
            ),
        ],
        if (note.openQuestions.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Open questions', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final question in note.openQuestions)
            _Cited(
              quote: question.sourceRef.quote,
              child:
                  Text(question.question, style: theme.textTheme.bodyMedium),
            ),
        ],
        const SizedBox(height: 32),
        _Provenance(recording: recording),
      ],
    );
  }
}

/// Action items. Grouped by status — the same group-by the Kanban board will use in
/// Phase 3, which is why no second model call is needed for either.
class _ActionsTab extends StatelessWidget {
  const _ActionsTab({required this.note});

  final NoteDocument note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (note.tasks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No action items came out of this recording.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final dated = note.schedulable;
    final undated = note.needsDates;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        for (final task in dated) _TaskTile(task: task, participants: note.participants),
        if (undated.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Text('No date discussed', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Nobody said when these were due, so nothing has been guessed for them.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final task in undated)
            _TaskTile(task: task, participants: note.participants),
        ],
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.participants});

  final NoteTask task;
  final List<Participant> participants;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owner = _ownerName();

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title, style: theme.textTheme.titleSmall),
            if (task.detail != null) ...[
              const SizedBox(height: 4),
              Text(task.detail!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (owner != null) _Chip(icon: Icons.person_outline, label: owner),
                if (task.priority != TaskPriority.medium)
                  _Chip(
                    icon: Icons.flag_outlined,
                    label: task.priority.name,
                    tone: task.priority == TaskPriority.critical
                        ? theme.colorScheme.error
                        : null,
                  ),
                _DateChip(task: task),
              ],
            ),
          ],
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

/// Renders the three date states differently, and never the same.
///
/// A spoken date and a date the model derived from "end of next sprint" are not the same
/// fact, and showing them identically is how a chart ends up implying certainty that was
/// never in the room.
class _DateChip extends StatelessWidget {
  const _DateChip({required this.task});

  final NoteTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (task.dateBasis) {
      DateBasis.explicit => _Chip(
          icon: Icons.event_available,
          label: task.dueDate ?? '',
          tone: theme.colorScheme.primary,
        ),
      DateBasis.inferred => _Chip(
          icon: Icons.event_note,
          label: '${task.dueDate ?? ''} · inferred',
          tone: theme.colorScheme.tertiary,
        ),
      DateBasis.absent => const _Chip(
          icon: Icons.event_busy,
          label: 'no date discussed',
        ),
    };
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, this.tone});

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
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.labelMedium?.copyWith(color: color)),
      ],
    );
  }
}

class _TranscriptTab extends StatelessWidget {
  const _TranscriptTab({required this.note});

  final NoteDocument note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Phase 1 reconstructs the reading view from the cited spans. Phase 2 stores the
    // full transcript alongside the note and plays it back in sync with the audio.
    final refs = [
      ...note.sections.map((s) => (s.sourceRef, s.heading)),
      ...note.decisions.map((d) => (d.sourceRef, d.statement)),
      ...note.tasks.map((t) => (t.sourceRef, t.title)),
    ]..sort((a, b) => (a.$1.startMs ?? 0).compareTo(b.$1.startMs ?? 0));

    if (refs.isEmpty) {
      return const Center(child: Text('No transcript was stored.'));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      itemCount: refs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (context, i) {
        final (ref, label) = refs[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _timestamp(ref.startMs),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 4),
            Text('“${ref.quote}”', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        );
      },
    );
  }

  static String _timestamp(int? ms) =>
      ms == null ? '—' : formatDuration(Duration(milliseconds: ms));
}

/// Shows the words an item was drawn from. Provenance is the whole reason the schema
/// requires a quote, so the UI shows it rather than hiding it behind a tap.
class _Cited extends StatelessWidget {
  const _Cited({required this.quote, required this.child});

  final String quote;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          const SizedBox(height: 3),
          Text(
            '“$quote”',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

class _Caveat extends StatelessWidget {
  const _Caveat({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }
}

/// Which services produced this note, and what it cost. Users spending their own API
/// credit are owed both.
class _Provenance extends StatelessWidget {
  const _Provenance({required this.recording});

  final db.Recording recording;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = recording.inputTokens == null
        ? null
        : '${recording.inputTokens} in · ${recording.outputTokens ?? 0} out';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: theme.colorScheme.outlineVariant),
        const SizedBox(height: 10),
        Text(
          [
            if (recording.transcriptionProviderId != null)
              'Transcribed by ${recording.transcriptionProviderId}',
            if (recording.structuringProviderId != null)
              'written by ${recording.structuringProviderId}',
            if (tokens != null) tokens,
          ].join(' · '),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
