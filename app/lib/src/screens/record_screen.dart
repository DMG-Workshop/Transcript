import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../recording/recording_controller.dart';
import '../widgets/waveform.dart';
import 'library_screen.dart';
import 'note_screen.dart';

/// Record, then watch it become notes.
class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  final List<double> _levels = [];

  @override
  void initState() {
    super.initState();
    ref.read(recorderProvider).levels.listen((level) {
      if (!mounted) return;
      setState(() {
        _levels.add(level);
        // An hour at 10 Hz is 36,000 samples; only the visible tail is ever drawn.
        if (_levels.length > 2000) _levels.removeRange(0, 500);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(recordingControllerProvider);

    ref.listen<RecordState>(recordingControllerProvider, (previous, next) {
      if (next is RecordDone) {
        setState(_levels.clear);
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => NoteScreen(recordingId: next.recordingId),
        ));
        if (next.warning != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(next.warning!)),
          );
        }
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transcript'),
        actions: [
          IconButton(
            icon: const Icon(Icons.library_books_outlined),
            tooltip: 'Recordings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LibraryScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: RecordBody(state: state, levels: _levels),
        ),
      ),
      floatingActionButton: switch (state) {
        RecordActive() => FloatingActionButton.large(
            onPressed: () => ref
                .read(recordingControllerProvider.notifier)
                .stopAndProcess(),
            tooltip: 'Stop and write notes',
            child: const Icon(Icons.stop),
          ),
        RecordProcessing() => null,
        _ => FloatingActionButton.large(
            onPressed: () =>
                ref.read(recordingControllerProvider.notifier).startRecording(),
            tooltip: 'Start recording',
            child: const Icon(Icons.mic),
          ),
      },
    );
  }
}

/// Maps recording state to what is on screen.
///
/// Separated from [RecordScreen] so the five states can be exercised directly, without a
/// microphone, a provider, or a database behind them.
class RecordBody extends StatelessWidget {
  const RecordBody({super.key, required this.state, this.levels = const []});

  final RecordState state;
  final List<double> levels;

  @override
  Widget build(BuildContext context) => switch (state) {
        RecordIdle() => const _IdlePane(),
        final RecordActive s => _ActivePane(state: s, levels: levels),
        final RecordProcessing s => _ProcessingPane(state: s),
        // Navigation to the note happens in a listener; the pane behind it returns to
        // rest so a second recording can start immediately.
        RecordDone() => const _IdlePane(),
        final RecordError s => _ErrorPane(state: s),
      };
}

class _IdlePane extends StatelessWidget {
  const _IdlePane();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.graphic_eq,
            size: 56, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
        const SizedBox(height: 20),
        Text('Ready to record', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 10),
        Text(
          'Everything goes straight from this device to the AI you chose. '
          'Nothing passes through anyone else.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ActivePane extends StatelessWidget {
  const _ActivePane({required this.state, required this.levels});

  final RecordActive state;
  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatDuration(state.elapsed),
              style: theme.textTheme.displaySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        SizedBox(height: 120, child: Waveform(levels: levels)),
        const SizedBox(height: 28),
        if (state.liveText.isNotEmpty)
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              child: Text(
                state.liveText,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          )
        else
          Expanded(
            child: Center(
              child: Text(
                'Listening',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
      ],
    );
  }
}

class _ProcessingPane extends StatelessWidget {
  const _ProcessingPane({required this.state});

  final RecordProcessing state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 220,
          // A real fraction where one exists. On a long recording this runs for minutes,
          // and an indeterminate spinner is what makes people force-quit.
          child: LinearProgressIndicator(value: state.fraction),
        ),
        const SizedBox(height: 20),
        Text(state.label, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _ErrorPane extends ConsumerWidget {
  const _ErrorPane({required this.state});

  final RecordError state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.error_outline, size: 44, color: theme.colorScheme.error),
        const SizedBox(height: 16),
        Text(state.message,
            textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        if (state.remedy != null) ...[
          const SizedBox(height: 10),
          Text(
            state.remedy!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (state.recordingId != null) ...[
          const SizedBox(height: 20),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => NoteScreen(recordingId: state.recordingId!),
              ),
            ),
            child: const Text('Open the transcript'),
          ),
        ],
      ],
    );
  }
}

/// mm:ss, or h:mm:ss once the recording is long enough to need it.
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
