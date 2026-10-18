import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';

/// 桌面窗口几何守卫：**启动就居中**，并且永远不让窗口停到屏幕外。
///
/// 为什么需要（客户实测 2026-10-18）：「某些 Windows 电脑装好后进程在跑、托盘有图标，
/// 但主界面就是打不开」。真因是窗口几何算错了 ——
/// 原生入口用 `GetSystemMetrics`（**主屏物理像素**）算居中，而 Flutter 的
/// `Win32Window::Create` 把传入值当**逻辑像素**再乘 DPI 缩放：
///   · 1920×1080 @150% 的笔记本：420×780 逻辑 → 物理 630×1170，比屏幕还高，
///     下半屏内容全部落在屏幕外；
///   · 1366×768 @125%：y 算出 -6 逻辑 → 物理 -7，标题栏跑到屏幕上方之外，
///     窗口只露出一部分且用户拖不回来 —— 结论就是"打不开界面"。
///
/// 原生侧（windows/runner/main.cpp 的 ComputeWindowGeometry / EnsureWindowOnScreen）
/// 已经按显示器工作区重算并带自愈；本类负责 Dart 侧的两件事：
///   1. **启动后居中**（用户明确要求「软件运行之后界面要在电脑正中间」）；
///   2. 从托盘/二次启动把窗口唤回时，先确认它还在可见区域内，离谱就叫回中间
///      （显示器热插拔、切换远程桌面、旧版本遗留的屏外坐标都能救回来）。
class WindowGeometry {
  WindowGeometry._();

  /// 离谱坐标判定：窗口整体落在这个范围之外就当它「不在任何屏幕上」。
  /// 正常多显示器布局的坐标都在 ±8000 以内，屏幕外残留常是几万甚至负数。
  static const double _saneLimit = 20000;
  static const double _saneMin = -20000;

  /// 窗口是否明显在屏幕外（宽高也参与判断：0/负尺寸同样算异常）
  @visibleForTesting
  static bool isOffScreen(Rect bounds) {
    if (bounds.width < 200 || bounds.height < 200) return true;
    if (bounds.left < _saneMin || bounds.top < _saneMin) return true;
    if (bounds.left > _saneLimit || bounds.top > _saneLimit) return true;
    return false;
  }

  /// 启动时调用：**无条件居中**（满足"界面在正中间"），并把异常尺寸拉回可用范围。
  ///
  /// 只在桌面端生效；任何异常都只记日志，绝不阻塞启动。
  static Future<void> centerOnLaunch() async {
    if (kIsWeb || !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    try {
      await windowManager.ensureInitialized();
    } catch (_) {
      return; // main 里已经 ensure 过；失败说明窗口系统不可用，直接放弃
    }
    try {
      final size = await windowManager.getSize();
      if (size.width < 320 || size.height < 480) {
        await windowManager.setSize(const Size(420, 780));
      }
    } catch (e) {
      AppLog.error('窗口尺寸校正失败: $e');
    }
    try {
      // center() 会按「光标所在显示器」的可见区域（去掉任务栏）计算位置
      await windowManager.center();
      AppLog.log('WINDOW', '启动居中完成');
    } catch (e) {
      AppLog.error('窗口居中失败: $e');
    }
  }

  /// 显示窗口（托盘点击 / 二次启动 / 自愈看门狗都走这里）：
  /// 先 show + focus，再检查是否被摆到屏幕外，离谱就拉回正中。
  static Future<void> showAndFocus() async {
    try {
      await windowManager.show();
    } catch (e) {
      AppLog.error('窗口显示失败: $e');
    }
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
    } catch (_) {}
    await ensureOnScreen();
    try {
      await windowManager.focus();
    } catch (e) {
      AppLog.error('窗口置前失败: $e');
    }
  }

  /// 只在「窗口明显在屏幕外」时才居中，避免把用户自己摆好的位置拽走。
  static Future<void> ensureOnScreen() async {
    try {
      final bounds = await windowManager.getBounds();
      if (!isOffScreen(bounds)) return;
      AppLog.error('窗口在屏幕外（$bounds）→ 拉回屏幕正中间');
      try {
        if (bounds.width < 320 || bounds.height < 480) {
          await windowManager.setSize(const Size(420, 780));
        }
      } catch (_) {}
      await windowManager.center();
    } catch (e) {
      AppLog.error('窗口位置自愈失败: $e');
    }
  }
}
