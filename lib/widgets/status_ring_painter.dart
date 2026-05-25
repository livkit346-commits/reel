import 'dart:math';
import 'package:flutter/material.dart';

class StatusRingPainter extends CustomPainter {
  final int statusCount;
  final int viewedCount;
  final Color viewedColor;
  final Color unviewedColor;
  final double strokeWidth;
  final double spacing;

  StatusRingPainter({
    required this.statusCount,
    this.viewedCount = 0,
    this.viewedColor = Colors.grey,
    this.unviewedColor = const Color(0xFF00BFFF),
    this.strokeWidth = 3.0,
    this.spacing = 0.08, // Adjust space between segments
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    
    // If only 1 status, draw a full continuous circle
    if (statusCount <= 1) {
      final paint = Paint()
        ..color = viewedCount > 0 ? viewedColor : unviewedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, 0, 2 * pi, false, paint);
      return;
    }

    // Multiple statuses: calculate angle per segment
    final totalSpacing = spacing * statusCount;
    final sweepAngle = ((2 * pi) - totalSpacing) / statusCount;
    
    // Start at the top (which is -pi / 2 in radians)
    double startAngle = -pi / 2;

    for (int i = 0; i < statusCount; i++) {
      final isViewed = i < viewedCount;
      final paint = Paint()
        ..color = isViewed ? viewedColor : unviewedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
      startAngle += sweepAngle + spacing;
    }
  }

  @override
  bool shouldRepaint(covariant StatusRingPainter oldDelegate) {
    return oldDelegate.statusCount != statusCount ||
        oldDelegate.viewedCount != viewedCount ||
        oldDelegate.viewedColor != viewedColor ||
        oldDelegate.unviewedColor != unviewedColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.spacing != spacing;
  }
}
