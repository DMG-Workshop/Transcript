import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import 'task_editor.dart';

/// The timeline, where `dateBasis` finally has to be visible.
///
/// A date someone spoke and a date the model derived are identical as values and must
/// never be identical on screen: solid bars for what was said, hatched ghosts for what
/// was inferred, and a tray beside the chart for work nobody dated at all. A Gantt that
/// renders all three the same way is exactly the confident-looking fiction this app was
/// designed not to produce.
class TimelineView extends ConsumerStatefulWidget {
  const TimelineView({super.key, required this.recordingId, required this.note});

  final String recordingId;
  final NoteDocument note;

  @override
  ConsumerState<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends ConsumerState<TimelineView> {
  TimelineScale _scale = TimelineScale.week;

  static const double rowHeight = 40;
  static const double labelWidth = 150;

  double get _pixelsPerDay => switch (_scale) {
        TimelineScale.day => 44,
        TimelineScale.week => 14,
        TimelineScale.month => 5,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = const TimelinePlanner().plan(widget.note);

    if (layout.isEmpty) {
      return _EmptyTimeline(
        undated: layout.undated,
        recordingId: widget.recordingId,
        note: widget.note,
      );
    }

    final chartWidth = layout.totalDays * _pixelsPerDay;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScaleBar(
          scale: _scale,
          inferredCount: layout.inferredCount,
          onChanged: (s) => setState(() => _scale = s),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Labels stay put while the chart scrolls; a bar with no visible name
                // is not worth drawing.
                SizedBox(
                  width: labelWidth,
                  child: Column(
                    children: [
                      const SizedBox(height: 28),
                      for (final bar in layout.bars)
                        SizedBox(
                          height: rowHeight,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 16, right: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                bar.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: chartWidth,
                      height: 28 + layout.bars.length * rowHeight,
                      child: CustomPaint(
                        painter: TimelinePainter(
                          layout: layout,
                          pixelsPerDay: _pixelsPerDay,
                          rowHeight: rowHeight,
                          scheme: theme.colorScheme,
                          textDirection: Directionality.of(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (layout.undated.isNotEmpty)
          _UndatedTray(
            tasks: layout.undated,
            recordingId: widget.recordingId,
            note: widget.note,
          ),
      ],
    );
  }
}

class _ScaleBar extends StatelessWidget {
  const _ScaleBar({
    required this.scale,
    required this.inferredCount,
    required this.onChanged,
  });

  final TimelineScale scale;
  final int inferredCount;
  final ValueChanged<TimelineScale> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          SegmentedButton<TimelineScale>(
            segments: [
              for (final s in TimelineScale.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {scale},
            showSelectedIcon: false,
            onSelectionChanged: (set) => onChanged(set.first),
          ),
          const Spacer(),
          if (inferredCount > 0)
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 14, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      '$inferredCount inferred',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.tertiary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Draws the chart. Split out so the geometry is one object with one job.
class TimelinePainter extends CustomPainter {
  TimelinePainter({
    required this.layout,
    required this.pixelsPerDay,
    required this.rowHeight,
    required this.scheme,
    required this.textDirection,
  });

  final TimelineLayout layout;
  final double pixelsPerDay;
  final double rowHeight;
  final ColorScheme scheme;
  final TextDirection textDirection;

  static const double headerHeight = 28;
  static const double barHeight = 20;

  @override
  void paint(Canvas canvas, Size size) {
    _paintMonthGrid(canvas, size);
    _paintMilestones(canvas, size);
    _paintLinks(canvas);
    _paintBars(canvas);
  }

  double _x(DateTime date) =>
      date.difference(layout.rangeStart).inDays * pixelsPerDay;

  double _rowCentre(int row) =>
      headerHeight + row * rowHeight + rowHeight / 2;

  void _paintMonthGrid(Canvas canvas, Size size) {
    final line = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    var cursor = DateTime(layout.rangeStart.year, layout.rangeStart.month, 1);
    while (cursor.isBefore(layout.rangeEnd)) {
      final x = _x(cursor);
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(Offset(x, headerHeight), Offset(x, size.height), line);
        _label(canvas, _monthName(cursor), Offset(x + 4, 8), scheme.onSurfaceVariant, 10);
      }
      cursor = DateTime(cursor.year, cursor.month + 1, 1);
    }
  }

  void _paintMilestones(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = scheme.error
      ..strokeWidth = 1.5;

    for (final milestone in layout.milestones) {
      final x = _x(milestone.date);
      canvas.drawLine(Offset(x, headerHeight), Offset(x, size.height), paint);
      // A small diamond, so a milestone reads differently from a task at a glance.
      final path = Path()
        ..moveTo(x, headerHeight - 6)
        ..lineTo(x + 5, headerHeight)
        ..lineTo(x, headerHeight + 6)
        ..lineTo(x - 5, headerHeight)
        ..close();
      canvas.drawPath(path, Paint()..color = scheme.error);
      _label(canvas, milestone.label, Offset(x + 8, headerHeight - 6), scheme.error, 10);
    }
  }

  void _paintLinks(Canvas canvas) {
    final byId = {for (final bar in layout.bars) bar.taskId: bar};
    final paint = Paint()
      ..color = scheme.onSurfaceVariant.withValues(alpha: 0.6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    for (final link in layout.links) {
      final from = byId[link.fromTaskId];
      final to = byId[link.toTaskId];
      if (from == null || to == null) continue;

      final startX = _x(from.end) + pixelsPerDay;
      final startY = _rowCentre(from.row);
      final endX = _x(to.start);
      final endY = _rowCentre(to.row);

      // An elbow rather than a diagonal: it stays readable when rows are close together.
      final midX = startX + 8;
      canvas.drawPath(
        Path()
          ..moveTo(startX, startY)
          ..lineTo(midX, startY)
          ..lineTo(midX, endY)
          ..lineTo(endX, endY),
        paint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(endX, endY)
          ..lineTo(endX - 5, endY - 3)
          ..lineTo(endX - 5, endY + 3)
          ..close(),
        Paint()..color = scheme.onSurfaceVariant.withValues(alpha: 0.6),
      );
    }
  }

  void _paintBars(Canvas canvas) {
    for (final bar in layout.bars) {
      final left = _x(bar.start);
      final width = (bar.durationDays * pixelsPerDay).clamp(6.0, double.infinity);
      final top = _rowCentre(bar.row) - barHeight / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, width, barHeight),
        const Radius.circular(4),
      );

      switch (bar.basis) {
        case DateBasis.explicit:
          // Solid: somebody said this date out loud.
          canvas.drawRRect(rect, Paint()..color = scheme.primary);
        case DateBasis.inferred:
          // Hatched and outlined: derived from the recording, not stated.
          canvas.drawRRect(
            rect,
            Paint()..color = scheme.tertiary.withValues(alpha: 0.18),
          );
          _hatch(canvas, rect, scheme.tertiary);
          canvas.drawRRect(
            rect,
            Paint()
              ..color = scheme.tertiary
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
        case DateBasis.absent:
          // Never drawn — an undated task has no honest position on a chart.
          break;
      }
    }
  }

  /// Diagonal hatching, clipped to the bar.
  void _hatch(Canvas canvas, RRect rect, Color color) {
    canvas.save();
    canvas.clipRRect(rect);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var x = rect.left - rect.height; x < rect.right; x += 5) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        paint,
      );
    }
    canvas.restore();
  }

  void _label(Canvas canvas, String text, Offset at, Color color, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: textDirection,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 120);
    painter.paint(canvas, at);
  }

  static String _monthName(DateTime d) => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ][d.month - 1];

  @override
  bool shouldRepaint(TimelinePainter old) =>
      old.pixelsPerDay != pixelsPerDay ||
      old.layout != layout ||
      old.scheme != scheme;
}

/// Work nobody dated, offered for the user to date themselves.
class _UndatedTray extends ConsumerWidget {
  const _UndatedTray({
    required this.tasks,
    required this.recordingId,
    required this.note,
  });

  final List<NoteTask> tasks;
  final String recordingId;
  final NoteDocument note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Needs dates', style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            'Nobody said when these were due, so nothing has been guessed. '
            'Tap one to place it.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final task in tasks)
                ActionChip(
                  avatar: const Icon(Icons.event_busy, size: 15),
                  label: Text(task.title, overflow: TextOverflow.ellipsis),
                  onPressed: () => openTaskEditor(
                    context,
                    ref,
                    recordingId: recordingId,
                    note: note,
                    task: task,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyTimeline extends ConsumerWidget {
  const _EmptyTimeline({
    required this.undated,
    required this.recordingId,
    required this.note,
  });

  final List<NoteTask> undated;
  final String recordingId;
  final NoteDocument note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.event_busy,
                      size: 40, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 14),
                  Text('Nothing on the timeline yet',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    undated.isEmpty
                        ? 'No dates were discussed in this recording.'
                        : 'No dates were discussed, so nothing has been placed. '
                            'Date a task below and it will appear here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (undated.isNotEmpty)
          _UndatedTray(tasks: undated, recordingId: recordingId, note: note),
      ],
    );
  }
}
