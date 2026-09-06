import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:transcript_core/transcript_core.dart';

import '../privacy/crash_log.dart';
import '../recording/recording_controller.dart';

/// What the app does with each kind of data, and the crash reports it is holding.
///
/// Rendered from [PrivacyDisclosure] — the same list `tool/export_privacy.dart` turns
/// into the doc the store answers are copied from. A user reading this screen and a
/// reviewer reading the listing are looking at one source of truth, so the two cannot
/// disagree.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final posture = ref.watch(settingsStoreProvider).posture;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Text(
              'There is no account, no analytics, and no server of ours in the '
              'middle. What leaves this device depends only on which AI you chose, '
              'and right now that is:',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: posture.posture == DataPosture.cloud
                    ? theme.colorScheme.tertiaryContainer
                    : theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(posture.summary, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(posture.detail, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final practice in PrivacyDisclosure.practices)
            _PracticeTile(practice: practice),
          const Divider(height: 32),
          const _CrashReportsSection(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _PracticeTile extends StatelessWidget {
  const _PracticeTile({required this.practice});

  final DataPractice practice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staysPut = practice.destination == DataDestination.device;

    return ExpansionTile(
      leading: Icon(
        staysPut ? Icons.phone_iphone : Icons.cloud_upload_outlined,
        color: staysPut
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(practice.label),
      subtitle: Text(practice.destination.label),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(practice.plainLanguage, style: theme.textTheme.bodyMedium),
        if (practice.userControls != null) ...[
          const SizedBox(height: 10),
          Text(
            practice.userControls!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// The crash reports held on the device: how many, and what to do with them.
///
/// Showing them at all is the point. Reports are only kept locally, so the user is the
/// one who decides whether a crash gets shared — which is a choice they can only make
/// if they can see what would be sent.
class _CrashReportsSection extends ConsumerWidget {
  const _CrashReportsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // `valueOrNull` rather than a full `when`: a failure to read the log is not worth
    // an error state on a privacy screen, and "checking…" is the honest thing to show
    // while it resolves either way.
    final reports = ref.watch(crashReportsProvider).valueOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Semantics(
            header: true,
            child: Text('Crash reports', style: theme.textTheme.titleSmall),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            reports == null
                ? 'Checking…'
                : reports.isEmpty
                    ? 'None. Nothing has crashed on this device.'
                    : '${reports.length} report${reports.length == 1 ? '' : 's'} '
                        'stored on this device. Nothing has been sent anywhere.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (reports != null && reports.isNotEmpty) ...[
          for (final report in reports.reversed.take(5))
            ListTile(
              dense: true,
              leading: const Icon(Icons.bug_report_outlined),
              title: Text(
                report.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${report.at.toLocal()} · app ${report.appVersion}',
              ),
              onTap: () => _showReport(context, report),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: renderCrashBundle(reports),
                      subject: 'Transcript diagnostics',
                    ),
                  ),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Share'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () async {
                    await ref.read(diagnosticsProvider).archive.clear();
                    ref.invalidate(crashReportsProvider);
                  },
                  child: const Text('Delete all'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _showReport(BuildContext context, CrashReport report) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(report.summary,
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 12),
                SelectableText(
                  report.detail,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
