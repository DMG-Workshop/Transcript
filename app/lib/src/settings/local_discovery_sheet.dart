import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import 'provider_config.dart';

/// Finds model servers on the user's network so they do not have to know their laptop's
/// IP address.
///
/// Typing an address is still offered and still works — discovery is a convenience, not
/// a requirement, and on a network that blocks peer traffic it will find nothing while
/// a typed address works fine.
Future<DiscoveredServer?> findLocalServer(BuildContext context) =>
    showModalBottomSheet<DiscoveredServer>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _DiscoverySheet(),
    );

class _DiscoverySheet extends ConsumerStatefulWidget {
  const _DiscoverySheet();

  @override
  ConsumerState<_DiscoverySheet> createState() => _DiscoverySheetState();
}

class _DiscoverySheetState extends ConsumerState<_DiscoverySheet> {
  final List<DiscoveredServer> _found = [];
  StreamSubscription<DiscoveredServer>? _scan;
  bool _scanning = false;
  final _subnet = TextEditingController();

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    _subnet.dispose();
    super.dispose();
  }

  void _start({String? subnetPrefix}) {
    unawaited(_scan?.cancel());
    setState(() {
      _found.clear();
      _scanning = true;
    });

    final discovery =
        LocalServerDiscovery(transport: ref.read(transportProvider));
    _scan = discovery.scan(subnetPrefix: subnetPrefix).listen(
      (server) {
        if (mounted) setState(() => _found.add(server));
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      onError: (_) {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Models on your network', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                if (_scanning)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Looking for Ollama and LM Studio on this device and the usual addresses.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            if (_found.isEmpty && !_scanning)
              _NothingFound(onScanSubnet: () => _start(subnetPrefix: _prefix()))
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _found.length,
                  itemBuilder: (context, i) {
                    final server = _found[i];
                    return ListTile(
                      leading: Icon(
                        server.isUsable ? Icons.dns : Icons.dns_outlined,
                        color: server.isUsable
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(server.label),
                      subtitle: Text(
                        server.isUsable
                            ? '${server.models.length} model'
                                '${server.models.length == 1 ? '' : 's'} · '
                                '${server.latency.inMilliseconds} ms'
                            : 'Running, but no models loaded yet',
                      ),
                      // A server with nothing loaded cannot be used, and offering it
                      // would only produce a confusing failure one screen later.
                      enabled: server.isUsable,
                      onTap: () => Navigator.of(context).pop(server),
                    );
                  },
                ),
              ),

            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _subnet,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Scan a network',
                      hintText: '192.168.1',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed:
                      _scanning ? null : () => _start(subnetPrefix: _prefix()),
                  child: const Text('Scan'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? _prefix() {
    final value = _subnet.text.trim();
    return value.isEmpty ? null : value;
  }
}

class _NothingFound extends StatelessWidget {
  const _NothingFound({required this.onScanSubnet});

  final VoidCallback onScanSubnet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Nothing found yet', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Three things usually explain this: the server is not running; it is bound '
            'to 127.0.0.1 rather than 0.0.0.0 (for Ollama, set OLLAMA_HOST=0.0.0.0); or '
            'this phone is on a different network. On iOS, Local Network access must '
            'also be allowed — if it was declined, nothing will ever answer.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Text(
            'You can also enter the address yourself — discovery is a convenience, not '
            'a requirement.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
