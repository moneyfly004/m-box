import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/widgets/traffic_chart.dart';

/// 用户要求：速率图要是**一张卡片里两条不同颜色的曲线**（上行/下行），
/// 而不是"上行一张卡、下行一张卡"。这里把"两条曲线真的都画出来了"钉住：
/// 直接渲染成位图，检查两种颜色的像素都存在。
const _upColor = Color(0xFF3B82F6); // 蓝
const _downColor = Color(0xFF22C55E); // 绿

Future<Map<Color, int>> _countColors(WidgetTester tester,
    {required List<double> up, required List<double> down}) async {
  final counts = <Color, int>{};
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(180, 60);
    TrafficChartPainter(
      upSamples: up,
      downSamples: down,
      upColor: _upColor,
      downColor: _downColor,
    ).paint(canvas, size);
    final image = await recorder
        .endRecording()
        .toImage(size.width.toInt(), size.height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    for (final target in [_upColor, _downColor]) {
      var hit = 0;
      for (var i = 0; i + 3 < bytes.length; i += 4) {
        final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2], a = bytes[i + 3];
        if (a < 40) continue;
        // 近似匹配（曲线有反锯齿，取阈值而不是精确相等）
        if ((r - target.r * 255).abs() < 60 &&
            (g - target.g * 255).abs() < 60 &&
            (b - target.b * 255).abs() < 60) {
          hit++;
        }
      }
      counts[target] = hit;
    }
  });
  return counts;
}

void main() {
  testWidgets('一张图两条曲线：上行蓝、下行绿都真的画出来了', (tester) async {
    final counts = await _countColors(
      tester,
      up: List.generate(40, (i) => 0.6 + (i % 5) * 0.05),
      down: List.generate(40, (i) => 2.0 + (i % 7) * 0.10),
    );
    expect(counts[_upColor]!, greaterThan(30), reason: '上行曲线必须画出来（蓝色）');
    expect(counts[_downColor]!, greaterThan(30), reason: '下行曲线必须画出来（绿色）');
  });

  testWidgets('数据为空（刚启动/未连接）时：只画基线，不抛异常', (tester) async {
    final counts = await _countColors(tester, up: const [], down: const []);
    expect(counts[_upColor]! + counts[_downColor]!, lessThan(30),
        reason: '没有采样时不该画曲线（只有基线）');
  });

  testWidgets('组件高度固定：有数据与无数据时一致（卡片不会跳）', (tester) async {
    Widget host(List<double> up, List<double> down) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: TrafficChart(
                upSamples: up,
                downSamples: down,
                upColor: _upColor,
                downColor: _downColor,
                height: 52,
              ),
            ),
          ),
        );

    await tester.pumpWidget(host(const [], const []));
    final empty = tester.getSize(find.byType(TrafficChart));
    await tester.pumpWidget(host(
      List.filled(40, 1.0),
      List.filled(40, 2.0),
    ));
    final filled = tester.getSize(find.byType(TrafficChart));
    expect(empty, filled, reason: '有无数据高度必须一致，否则订阅刷新会让卡片位移');
    expect(filled.height, 52);
  });
}
