import 'dart:async';

import 'package:flutter/material.dart';
import 'package:transcript_core/transcript_core.dart';

import '../net/dio_transport.dart';
import 'file_model_store.dart';

/// Opens a sheet for browsing, downloading and selecting an offline
/// whisper.cpp model. Returns the chosen model id, or null if the sheet was
/// dismissed without picking one.
Future<String?> showWhisperModelPicker(
  BuildContext context, {
  String? selectedModelId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _WhisperModelSheet(selectedModelId: selectedModelId),
  );
}

class _ModelState {
  bool completed = false;
  DownloadProgress? progress;
  String? error;

  bool get downloading => progress != null && !completed;
}

class _WhisperModelSheet extends StatefulWidget {
  const _WhisperModelSheet({this.selectedModelId});

  final String? selectedModelId;

  @override
  State<_WhisperModelSheet> createState() => _WhisperModelSheetState();
}

class _WhisperModelSheetState extends State<_WhisperModelSheet> {
  final _store = FileModelStore();
  late final _downloader = ModelDownloader(
    transport: DioTransport(),
    store: _store,
  );
  final Map<String, _ModelState> _states = {
    for (final model in WhisperCatalog.models) model.id: _ModelState(),
  };
  final Map<String, StreamSubscription<DownloadProgress>> _subs = {};

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCompletion());
  }

  Future<void> _refreshCompletion() async {
    for (final model in WhisperCatalog.models) {
      final done = await _store.isComplete(model.id);
      if (mounted) setState(() => _states[model.id]!.completed = done);
    }
  }

  @override
  void dispose() {
    for (final sub in _subs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  void _download(WhisperModel model) {
    final state = _states[model.id]!;
    if (state.downloading || state.completed) return;

    setState(() {
      state.error = null;
      state.progress = const DownloadProgress(receivedBytes: 0, totalBytes: 0);
    });

    _subs[model.id]?.cancel();
    _subs[model.id] = _downloader.download(model).listen(
      (progress) {
        if (!mounted) return;
        setState(() => state.progress = progress);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          state.progress = null;
          state.error = e is DownloadException ? e.reason : e.toString();
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          state.completed = true;
          state.progress = null;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Offline models', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Downloaded once, then decoding happens entirely on this device.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            for (final model in WhisperCatalog.models)
              _ModelTile(
                model: model,
                state: _states[model.id]!,
                selected: widget.selectedModelId == model.id,
                onDownload: () => _download(model),
                onSelect: () => Navigator.of(context).pop(model.id),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.state,
    required this.selected,
    required this.onDownload,
    required this.onSelect,
  });

  final WhisperModel model;
  final _ModelState state;
  final bool selected;
  final VoidCallback onDownload;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = state.progress;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(model.label, style: theme.textTheme.titleSmall),
                    const SizedBox(width: 8),
                    Text(
                      '${model.approxMegabytes.round()} MB',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                Text(
                  model.quality.description,
                  style: theme.textTheme.bodySmall,
                ),
                if (state.downloading) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: progress == null || progress.fraction == 0
                        ? null
                        : progress.fraction,
                  ),
                  if (progress != null && progress.totalBytes > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${progress.received} / ${progress.total}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      state.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (state.completed)
            selected
                ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                : OutlinedButton(
                    onPressed: onSelect,
                    child: const Text('Use'),
                  )
          else if (state.downloading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            FilledButton.tonal(
              onPressed: onDownload,
              child: const Text('Download'),
            ),
        ],
      ),
    );
  }
}
