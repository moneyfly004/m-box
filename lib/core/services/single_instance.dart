import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// 单实例守卫（macOS / Linux）。
///
/// Windows 由原生入口 `windows/runner/main.cpp` 的 `CreateMutexW` 在创建窗口前
/// 拦截；macOS/Linux 一直没有守卫 —— `open -n` 或命令行再启一次就能同时跑起两个
/// 实例，各自管理体系代理与内核：新实例的启动巡检会把**旧的活内核**当残留杀掉、
/// 把正在生效的系统代理当残留清掉（2026-09-14 17:54 的 `code=-1` 紧跟着
/// `startup: cleared residual system proxy` 就是这条路径）。
/// 内核收割现在已收窄为「只收真孤儿」、系统代理清扫也已加端口探活，误杀没了；
/// 但两个实例抢同一份系统代理/内核端口仍然没有意义，故补上守卫。
///
/// 实现用**排他文件锁**（[RandomAccessFile.lockSync]）：进程消亡时锁由系统自动
/// 释放，不会像 pid 文件那样留下「假锁」把用户挡在门外 —— 强杀、崩溃、断电都
/// 不会。锁文件句柄有意不关闭，随进程生命周期持有。
///
/// 环境变量 `MBOX_ALLOW_MULTI=1` 可显式放行（`flutter run` 连开两个调试
/// 实例时用）。
class SingleInstance {
  SingleInstance._();

  static RandomAccessFile? _lock;

  /// 测试注入点（flutter test 下 systemTemp 可用，但注入更可控）
  @visibleForTesting
  static Future<Directory> Function()? debugDir;

  /// 取锁：true = 可以继续启动；false = 已有实例在跑，调用方应尽快退出。
  /// 任何异常（只读临时目录、权限不足…）都放行并记录 —— 单实例是防误操作，
  /// 不是安全边界，绝不能因为它起不来就让用户打不开软件。
  static Future<bool> acquire({String name = 'mbox'}) async {
    if (kIsWeb) return true;
    if (Platform.environment['MBOX_ALLOW_MULTI'] == '1') return true;
    if (_lock != null) return true;
    try {
      final dir = debugDir != null ? await debugDir!() : Directory.systemTemp;
      final f = File('${dir.path}/$name.lock');
      final raf = await f.open(mode: FileMode.write);
      try {
        raf.lockSync(FileLock.exclusive);
      } on FileSystemException {
        await raf.close();
        return false;
      }
      _lock = raf;
      return true;
    } catch (e) {
      AppLog.log('APP', 'single instance lock unavailable: $e');
      return true;
    }
  }

  /// 主动放掉锁。
  ///
  /// **自更新专用**：macOS 就地安装完成后要用 `open -n` 起新实例，而新实例启动时
  /// 会抢同一把排他锁 —— 旧进程还持锁的话它会「抢不到锁 → 立刻退出」，
  /// 用户看到的现象就是「更新完什么都没发生、软件不见了」。
  /// 正常退出**不需要**调用：进程消亡时系统自动释放。
  static Future<void> release() async {
    try {
      _lock?.unlockSync();
      await _lock?.close();
    } catch (_) {}
    _lock = null;
  }

  /// 仅供测试：释放锁（等价于 [release]）
  @visibleForTesting
  static Future<void> releaseForTest() => release();
}
