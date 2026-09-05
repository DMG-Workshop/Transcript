import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A live level meter drawn as mirrored bars.
///
/// Its only job is to prove the app is listening. That sounds cosmetic and is not: the
/// single worst outcome in a recording app is a user who believes a meeting was captured
/// and finds silence, so the waveform has to move with the room.
class Waveform extends StatelessWidget {
  const Waveform({
    super.key,
    required this.levels,
    this.color,
    this.barWidth = 3,
    this.gap = 2,
  });

  /// Normalised 0..1, oldest first. Only the most recent bars that fit are drawn.
  final List<double> levels;
  final Color? color;
  final double barWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _WaveformPainter(
          levels: levels,
          color: color ?? Theme.of(context).colorScheme.primary,
          barWidth: barWidth,
          gap: gap,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.levels,
    required this.color,
    required this.barWidth,
    required this.gap,
  });

  final List<double> levels;
  final Color color;
  final double barWidth;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final stride = barWidth + gap;
    final capacity = math.max(1, (size.width / stride).floor());
    final visible = levels.length <= capacity
        ? levels
        : levels.sublist(levels.length - capacity);

    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    final midline = size.height / 2;
    // Newest bar sits at the right edge, so the trace scrolls leftwards as it fills.
    final startX = size.width - visible.length * stride + barWidth / 2;

    for (var i = 0; i < visible.length; i++) {
      // A floor keeps a quiet room visible as a thin line rather than nothing at all,
      // which would read as "not recording".
      final amplitude = math.max(0.04, visible[i]);
      final half = amplitude * midline * 0.92;
      final x = startX + i * stride;
      canvas.drawLine(Offset(x, midline - half), Offset(x, midline + half), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.levels.length != levels.length || old.color != color;
}
