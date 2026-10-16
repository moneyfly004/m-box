/// 速率曲线计算（纯函数，便于单测）。
///
/// 用户要求：首页速率图要像 FlClash 那样是**一条连续的整体曲线**，连着的时候
/// 一直在走；而不是每秒跳动的尖刺 —— 尖刺会让客户误以为"没有流量在传/时断时续"。
///
/// 三个关键点：
///   1) 滑动平均把 1 秒采样的毛刺抹平（真实吞吐的爆发仍然看得出来）；
///   2) 量程用**平滑后**的峰值 + 一个下限，曲线既不会贴底看不见，也不会每帧忽大忽小；
///   3) 用 Catmull-Rom 转三次贝塞尔画过点平滑曲线，两个采样点之间不再有折角。
library;

import 'dart:ui';

/// 滑动平均（居中窗口，边界自动收窄）。
///
/// window 越大越平稳、跟随越慢：
///   - 3 用于"当前速率"那条线（跟手但不毛）；
///   - 12 用于"整体趋势"那条线（就是用户要的平稳整体曲线）。
List<double> smoothSeries(List<double> raw, {int window = 5}) {
  if (raw.isEmpty) return const [];
  if (window <= 1) return List<double>.from(raw);
  final n = raw.length;
  final out = List<double>.filled(n, 0);
  final half = window ~/ 2;
  for (var i = 0; i < n; i++) {
    final lo = (i - half) < 0 ? 0 : i - half;
    final hi = (i + half) >= n ? n - 1 : i + half;
    var sum = 0.0;
    for (var j = lo; j <= hi; j++) {
      sum += raw[j];
    }
    out[i] = sum / (hi - lo + 1);
  }
  return out;
}

/// 曲线量程（MB/s）。
///
/// [floorMbps] 是下限：小流量（几十 KB/s）时曲线也看得见，不会贴底看起来像"没流量"。
/// 量程取自**传入序列**（调用方传平滑后的趋势线），所以不会因为单帧毛刺跳变。
double seriesPeak(List<double> values, {double floorMbps = 0.05}) {
  var maxV = 0.0;
  for (final v in values) {
    if (v > maxV) maxV = v;
  }
  if (maxV < floorMbps) return floorMbps;
  return maxV;
}

/// 序列 → 画布坐标点（x 均匀铺满宽度，y 按量程缩放并留 10% 顶部余量）。
List<Offset> toPoints(List<double> values, Size size, double peak) {
  if (values.isEmpty || size.width <= 0 || size.height <= 0) return const [];
  final safePeak = peak <= 0 ? 1.0 : peak;
  const topPad = 0.10;
  final usable = size.height * (1 - topPad);
  final n = values.length;
  final pts = <Offset>[];
  for (var i = 0; i < n; i++) {
    final x = n == 1 ? 0.0 : size.width * i / (n - 1);
    final ratio = (values[i] / safePeak).clamp(0.0, 1.0);
    pts.add(Offset(x, size.height - ratio * usable));
  }
  return pts;
}

/// 过点平滑曲线（Catmull-Rom → 三次贝塞尔）。
///
/// 折线直连会把相邻两秒的落差画成尖角，视觉上"一跳一跳"；这里按切线插值成
/// 连续曲率，看起来就是一条整体曲线。点数 < 2 时退化成一条水平基线。
Path smoothPath(List<Offset> pts, {double baselineY = 0}) {
  final path = Path();
  if (pts.isEmpty) return path;
  if (pts.length == 1) {
    path.moveTo(pts.first.dx, baselineY == 0 ? pts.first.dy : baselineY);
    path.lineTo(pts.first.dx, pts.first.dy);
    return path;
  }
  path.moveTo(pts.first.dx, pts.first.dy);
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = i == 0 ? pts[0] : pts[i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = (i + 2) < pts.length ? pts[i + 2] : pts.last;
    // Catmull-Rom 切线 → 贝塞尔控制点（1/6 系数为标准写法）
    final c1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
    final c2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path;
}

/// 曲线首尾相接到底部，做成可填充的闭合区域。
Path closeToBottom(Path line, Size size) {
  final bounds = line.getBounds();
  final fill = Path.from(line);
  fill.lineTo(bounds.right <= 0 ? size.width : bounds.right, size.height);
  fill.lineTo(bounds.left < 0 ? 0 : bounds.left, size.height);
  fill.close();
  return fill;
}
