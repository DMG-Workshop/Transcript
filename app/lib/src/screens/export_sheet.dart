import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:transcript_core/transcript_core.dart';

/// What a note can be turned into on its way out of the app.
enum ExportFormat {
  markdown(
    label: 'Markdown',
    detail: 'Notes, decisions and action items, for pasting into a doc.',
    extension: 'md',
    mime: 'text/markdown',
  ),
  csv(
    label: 'Spreadsheet (CSV)',
    detail: 'One row per action item, with a column saying how each date was known.',
    extension: 'csv',
    mime: 'text/csv',
  ),
  jira(
    label: 'Jira CSV',
    detail: 'Ready for Jira\'s importer. Only spoken dates fill the due-date field.',
    extension: 'csv',
    mime: 'text/csv',
  ),
  calendar(
    label: 'Calendar (.ics)',
    detail: 'Dated tasks and milestones. Undated work is left out rather than guessed.',
    extension: 'ics',
    mime: 'text/calendar',
  );

  const ExportFormat({
    required this.label,
    required this.detail,
    required this.extension,
    required this.mime,
  });

  final String label;
  final String detail;
  final String extension;
  final String mime;

  String render(NoteDocument note, {String? recordedOn}) => switch (this) {
        ExportFormat.markdown =>
          NoteExporters.markdown(note, recordedOn: recordedOn),
        ExportFormat.csv => NoteExporters.tasksCsv(note),
        ExportFormat.jira => NoteExporters.jiraCsv(note),
        ExportFormat.calendar => NoteExporters.ics(note),
      };
}

Future<void> openExportSheet(
  BuildContext context, {
  required NoteDocument note,
  String? recordedOn,
}) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => ExportSheet(note: note, recordedOn: recordedOn),
    );

/// Offers the note in each format, with a plain description of what each one keeps.
class ExportSheet extends StatelessWidget {
  const ExportSheet({super.key, required this.note, this.recordedOn});

  final NoteDocument note;
  final String? recordedOn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inferred =
        note.tasks.where((t) => t.dateBasis == DateBasis.inferred).length;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
            child: Text('Export', style: theme.textTheme.titleMedium),
          ),
          if (inferred > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                '$inferred date${inferred == 1 ? ' was' : 's were'} inferred from the '
                'recording rather than stated. Every export says so.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.tertiary),
              ),
            ),
          for (final format in ExportFormat.values)
            ListTile(
              title: Text(format.label),
              subtitle: Text(format.detail),
              trailing: const Icon(Icons.ios_share),
              onTap: () => _share(context, format),
              onLongPress: () => _copy(context, format),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              'Long-press to copy instead of sharing.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _share(BuildContext context, ExportFormat format) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final file = await _write(format);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: format.mime)],
        subject: note.meta.title,
      ));
      navigator.pop();
    } catch (e) {
      // Sharing can fail for reasons entirely outside the app — no handler installed,
      // storage full. Say so rather than closing the sheet as if it worked.
      messenger.showSnackBar(
        SnackBar(content: Text('Could not share the ${format.label} export.')),
      );
    }
  }

  Future<void> _copy(BuildContext context, ExportFormat format) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(text: format.render(note, recordedOn: recordedOn)),
    );
    messenger.showSnackBar(
      SnackBar(content: Text('${format.label} copied.')),
    );
  }

  Future<File> _write(ExportFormat format) async {
    final dir = await getTemporaryDirectory();
    final name = '${_slug(note.meta.title)}.${format.extension}';
    final file = File(p.join(dir.path, name));
    // Written as UTF-8 explicitly: transcripts carry names and terms that are not ASCII,
    // and a spreadsheet opening them as Latin-1 turns those into mojibake.
    await file.writeAsBytes(
      utf8.encode(format.render(note, recordedOn: recordedOn)),
    );
    return file;
  }

  static String _slug(String title) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'transcript-note' : slug;
  }
}
