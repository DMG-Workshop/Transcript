import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import 'connection_test_controller.dart';
import 'provider_config.dart';
import 'secure_key_store.dart';

/// The only screen in Phase 0.
///
/// Two independent slots, because transcription and structuring are different jobs with
/// different providers. The copy says so plainly rather than leaving the user to discover
/// that Claude will not accept their audio.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI providers')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [
          _Explainer(),
          _StageSection(stage: ProviderStage.transcription),
          Divider(height: 32),
          _StageSection(stage: ProviderStage.structuring),
          SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your AI, your keys', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Recordings go straight from this device to the service you choose. '
            'Nothing passes through our servers — there are none. Keys are stored in '
            'the device keychain and are never sent anywhere else.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Text(
            'Transcription and note-writing are separate steps and use separate '
            'services, because most of them only do one. On-device recognition plus a '
            'model on your own machine works with no key at all.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _StageSection extends ConsumerStatefulWidget {
  const _StageSection({required this.stage});

  final ProviderStage stage;

  @override
  ConsumerState<_StageSection> createState() => _StageSectionState();
}

class _StageSectionState extends ConsumerState<_StageSection> {
  late ProviderKind _kind = ProviderKind.forStage(widget.stage).first;
  final _keyController = TextEditingController();
  final _endpointController = TextEditingController();
  bool _keySaved = false;

  @override
  void initState() {
    super.initState();
    _refreshKeyState();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _endpointController.dispose();
    super.dispose();
  }

  Future<void> _refreshKeyState() async {
    final saved = await ref.read(keyStoreProvider).has(_kind.id);
    if (mounted) setState(() => _keySaved = saved);
  }

  ProviderSelection get _selection => ProviderSelection(
        kind: _kind,
        hasKey: _keySaved || _keyController.text.isNotEmpty,
        endpoint: _endpointController.text.trim().isEmpty
            ? null
            : _endpointController.text.trim(),
      );

  Future<void> _test() async {
    final key = _keyController.text.trim();
    if (key.isNotEmpty) {
      await ref.read(keyStoreProvider).write(_kind.id, key);
      _keyController.clear();
      await _refreshKeyState();
    }
    await ref
        .read(connectionTestProvider(widget.stage).notifier)
        .run(_selection, widget.stage);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(connectionTestProvider(widget.stage));
    final options = ProviderKind.forStage(widget.stage);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(widget.stage.label.toUpperCase(),
              style: theme.textTheme.labelSmall
                  ?.copyWith(letterSpacing: 1.2, color: theme.colorScheme.primary)),
        ),
        RadioGroup<ProviderKind>(
          groupValue: _kind,
          onChanged: (value) {
            if (value == null) return;
            setState(() => _kind = value);
            ref.read(connectionTestProvider(widget.stage).notifier).reset();
            unawaited(_refreshKeyState());
          },
          child: Column(
            children: [
              for (final option in options)
                RadioListTile<ProviderKind>(
                  value: option,
                  title: Text(option.label),
                  subtitle: Text(option.subtitle),
                ),
            ],
          ),
        ),
        if (_kind.needsEndpoint)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _endpointController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Address',
                hintText: 'http://192.168.1.50:${_kind == ProviderKind.ollama ? 11434 : 1234}',
                helperText: 'The computer running it must be on this network.',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        if (_kind.needsKey)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _keyController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                hintText: _keySaved ? 'A key is saved' : 'Paste your key',
                suffixIcon: _keySaved
                    ? IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove saved key',
                        onPressed: () async {
                          await ref.read(keyStoreProvider).delete(_kind.id);
                          await _refreshKeyState();
                        },
                      )
                    : null,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              FilledButton.tonal(
                onPressed: state is ConnectionTestRunning ? null : _test,
                child: state is ConnectionTestRunning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Test connection'),
              ),
              const SizedBox(width: 12),
              if (state is ConnectionTestDone)
                Expanded(child: _ResultChip(result: state.result)),
            ],
          ),
        ),
        if (state is ConnectionTestDone) _ResultDetail(result: state.result),
      ],
    );
  }
}

class _ResultChip extends StatelessWidget {
  const _ResultChip({required this.result});

  final ConnectionResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final good = result.ok;
    return Row(
      children: [
        Icon(good ? Icons.check_circle : Icons.error_outline,
            size: 18, color: good ? scheme.primary : scheme.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            result.summary,
            style: Theme.of(context).textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// The failure path is the reason this screen exists, so it gets the space: what the
/// provider said, and what to do about it.
class _ResultDetail extends StatelessWidget {
  const _ResultDetail({required this.result});

  final ConnectionResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (result.detail == null && result.remedy == null && result.models.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: result.ok
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result.remedy != null)
              Text(result.remedy!, style: theme.textTheme.bodyMedium),
            if (result.detail != null) ...[
              if (result.remedy != null) const SizedBox(height: 8),
              Text(
                result.detail!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (result.models.length > 1) ...[
              const SizedBox(height: 8),
              Text('Models: ${result.models.take(8).join(', ')}',
                  style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// Re-exported so the settings screen's imports stay short.
typedef MaskedKey = SecureKeyStore;
