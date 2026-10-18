import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/window_geometry.dart';

/// 客户实测（2026-10-18）：「某些 Windows 电脑装好后进程在跑、托盘有图标，
/// 但主界面打不开」，真因是窗口被摆到了屏幕外 / 尺寸超过屏幕。
///
/// 原生侧（windows/runner/main.cpp）已按显示器工作区重算几何；
/// 这里锁住 Dart 侧的判定口径：什么样的窗口算"在屏幕外，必须拉回中间"。
void main() {
  group('窗口是否在屏幕外', () {
    test('正常居中的窗口不算异常（不会把用户摆好的位置拽走）', () {
      expect(WindowGeometry.isOffScreen(const Rect.fromLTWH(560, 120, 420, 780)), isFalse);
      // 第二块显示器（右侧）也算正常
      expect(WindowGeometry.isOffScreen(const Rect.fromLTWH(2100, 200, 420, 780)), isFalse);
      // 副屏在左侧（负坐标）同样正常
      expect(WindowGeometry.isOffScreen(const Rect.fromLTWH(-1600, 100, 420, 780)), isFalse);
    });

    test('标题栏被顶到屏幕上方之外（坐标离谱）→ 判定异常', () {
      expect(WindowGeometry.isOffScreen(const Rect.fromLTWH(473, -30000, 420, 780)), isTrue);
    });

    test('窗口被摆到屏幕右侧之外 → 判定异常', () {
      expect(WindowGeometry.isOffScreen(const Rect.fromLTWH(40000, 300, 420, 780)), isTrue);
    });

    test('尺寸异常（过小 / 0）→ 判定异常（否则用户看到一个看不见的条）', () {
      expect(WindowGeometry.isOffScreen(const Rect.fromLTWH(100, 100, 0, 0)), isTrue);
      expect(WindowGeometry.isOffScreen(const Rect.fromLTWH(100, 100, 120, 300)), isTrue);
    });
  });
}

// 说明：窗口几何 + 看门狗 + 网络抖动三处 iOS/Windows 稳定性修复的判定口径，
// 分别见 test/window_geometry_test.dart（几何）、下面的 watchdog 判定矩阵。
