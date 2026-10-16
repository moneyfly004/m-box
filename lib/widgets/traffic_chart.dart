import 'package:flutter/material.dart';

import '../core/services/speed_series.dart';

/// 一张卡片里画**两条曲线**：上行 / 下行，用颜色区分（用户要求）。
///
/// 之前是"上行一张卡、下行一张卡"，各自一条瞬时折线：
///   - 看起来是两段互不相干的锯齿，"时断时续"；
///   - 两张卡还占了两份高度，矮窗口下一屏放不下。
///
/// 现在：一张卡、同一量程、两条平滑曲线（各自渐变填充），
/// 既是一个整体，也能一眼比较上下行的量级。
class TrafficChart extends StatelessWidget {
  const TrafficChart({
    super.key,
    required this.upSamples,
    required this.downSamples,
    required this.upColor,
    required this.downColor,
    this.height = 56,
    this.window = 6,
    this.peakFloorMbps = 0.05,
  });

  /// 上行速率采样（MB/s，1 秒一个，最新在末尾）
  final List<double> upSamples;

  /// 下行速率采样（MB/s，同上）
  final List<double> downSamples;

  final Color upColor;
  final Color downColor;
  final double height;

  /// 平滑窗口（秒）：越大越平稳，6 秒在"平稳"和"跟手"之间比较均衡
  final int window;

  /// 量程下限：小流量（几十 KB/s）也能看见曲线，不会贴底像"没流量"
  final double peakFloorMbps;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: TrafficChartPainter(
          upSamples: upSamples,
          downSamples: downSamples,
          upColor: upColor,
          downColor: downColor,
          window: window,
          peakFloorMbps: peakFloorMbps,
        ),
      ),
    );
  }
}

/// 纯绘制：两条曲线共用一套量程与坐标系。
class TrafficChartPainter extends CustomPainter {
  TrafficChartPainter({
    required this.upSamples,
    required this.downSamples,
    required this.upColor,
    required this.downColor,
    this.window = 6,
    this.peakFloorMbps = 0.05,
  });

  final List<double> upSamples;
  final List<double> downSamples;
  final Color upColor;
  final Color downColor;
  final int window;
  final double peakFloorMbps;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final baselineY = size.height - 0.8;
    final up = smoothSeries(upSamples, window: window);
    final down = smoothSeries(downSamples, window: window);

    // 量程：两条曲线共用（可比），并保留下限（小流量也看得见）
    final peak = seriesPeak([...up, ...down], floorMbps: peakFloorMbps);

    // 先画下行（通常量更大，压在后面），再画上行
    for (final series in [
      (values: down, color: downColor),
      (values: up, color: upColor),
    ]) {
      if (series.values.length < 2) continue;
      final pts = toPoints(series.values, size, peak);
      final line = smoothPath(pts);
      // 渐变填充：视觉上有"面积"，不像空图
      canvas.drawPath(
        closeToBottom(line, size),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              series.color.withValues(alpha: .30),
              series.color.withValues(alpha: .02),
            ],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
      );
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = series.color,
      );
    }

    // 基线常驻：空闲时也有一条连续底线，不显得"断了"
    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      Paint()
        ..strokeWidth = 1
        ..color = const Color(0x33FFFFFF),
    );
  }

  @override
  bool shouldRepaint(TrafficChartPainter old) =>
      old.upColor != upColor ||
      old.downColor != downColor ||
      old.window != window ||
      !_same(old.upSamples, upSamples) ||
      !_same(old.downSamples, downSamples);

  static bool _same(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
