import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/services/speed_series.dart';

/// 首页速率图的要求（用户提出）：要像 FlClash 那样是**一条连续的整体曲线**，
/// 连着的时候一直在走；不能是每秒跳动的尖刺 —— 尖刺会让客户误以为
/// "没有流量在传 / 时断时续"。这里把三个纯计算钉住。
void main() {
  test('滑动平均抹平毛刺：突发-空闲交替的采样不再"一跳一跳"', () {
    // 典型的间歇流量：1 秒有、1 秒没有（旧实现画出来就是锯齿）
    final spiky = <double>[1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0];
    double amplitude(List<double> v) {
      var lo = v.first, hi = v.first;
      for (final x in v) {
        if (x < lo) lo = x;
        if (x > hi) hi = x;
      }
      return hi - lo;
    }

    final smoothed = smoothSeries(spiky, window: 5);
    expect(amplitude(smoothed), lessThan(amplitude(spiky) * 0.5),
        reason: '平滑后振幅应明显变小（曲线连续，不再忽高忽低）');
    // 相邻样本落差也被压平（视觉上无尖角）
    var maxJump = 0.0;
    for (var i = 1; i < smoothed.length; i++) {
      final d = (smoothed[i] - smoothed[i - 1]).abs();
      if (d > maxJump) maxJump = d;
    }
    expect(maxJump, lessThan(0.35), reason: '相邻点落差要小，曲线才平稳');
  });

  test('全零（空闲）时量程仍大于 0：曲线贴底但连续可见，不像"空图"', () {
    final peak = seriesPeak(List<double>.filled(30, 0));
    expect(peak, greaterThan(0), reason: '量程为 0 会导致除零/曲线消失');
    final pts = toPoints(List<double>.filled(30, 0), const Size(120, 20), peak);
    expect(pts, hasLength(30));
    // 全部落在底部（贴底），但坐标有效（能画出一条连续基线）
    expect(pts.every((p) => p.dy >= 0 && p.dy <= 20), isTrue);
  });

  test('量程跟得上真实速率，且不会因为单个毛刺被拉爆', () {
    final steady = List<double>.filled(30, 2.0);
    expect(seriesPeak(smoothSeries(steady, window: 12)), closeTo(2.0, 0.01));

    // 一个尖刺（比如瞬时 50MB/s 的抖动）：平滑后不应把量程整体拉到 50
    final withSpike = List<double>.filled(30, 2.0)..[15] = 50.0;
    final peak = seriesPeak(smoothSeries(withSpike, window: 12));
    expect(peak, lessThan(10.0), reason: '单点毛刺不该把整条曲线压扁');
  });

  test('点坐标：x 均匀铺满宽度，y 随数值单调（越高越靠上）', () {
    final vals = <double>[0.0, 1.0, 2.0, 3.0];
    final pts = toPoints(vals, const Size(90, 20), 3.0);
    expect(pts.first.dx, 0);
    expect(pts.last.dx, closeTo(90, 0.001));
    for (var i = 1; i < pts.length; i++) {
      expect(pts[i].dx, greaterThan(pts[i - 1].dx));
      expect(pts[i].dy, lessThan(pts[i - 1].dy), reason: '值越大 y 越小（越高）');
    }
  });

  test('平滑路径：过点、可填充、点数不足时退化为基线', () {
    final pts = toPoints(<double>[1, 2, 3, 2, 1], const Size(100, 20), 3);
    final path = smoothPath(pts);
    final b = path.getBounds();
    expect(b.width, greaterThan(90), reason: '路径应铺满宽度');
    expect(b.left, closeTo(0, 1));
    expect(b.right, closeTo(100, 1));

    final fill = closeToBottom(path, const Size(100, 20));
    final fb = fill.getBounds();
    expect(fb.bottom, closeTo(20, 0.5), reason: '填充区域要接到底部');

    expect(smoothPath(const []).getBounds().isEmpty, isTrue);
    expect(smoothPath(<Offset>[const Offset(5, 5)]).getBounds().width, 0);
  });

  test('单点/空序列不抛异常（刚连接、断开清空时都要安全）', () {
    expect(smoothSeries(const []), isEmpty);
    expect(smoothSeries(<double>[1.0]), <double>[1.0]);
    expect(toPoints(const [], const Size(10, 10), 1), isEmpty);
    expect(toPoints(<double>[1], const Size(0, 0), 1), isEmpty);
  });
}
