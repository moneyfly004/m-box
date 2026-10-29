import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/app_log.dart';

/// 桌面端提权：检测「当前进程有没有 TUN 所需权限」，以及 Windows 上以管理员重启。
///
/// 为什么必须有它（2026-10-28 真机 / 虚拟机实证）：
/// Windows 的 TUN 要创建 wintun 虚拟网卡、改路由表，非管理员**必然**失败。
/// mihomo 在内核日志里只留一行
///   `Start TUN listening error: configure tun interface: Access is denied.`
/// 然后进程立即退出；App 侧看到的是「内核进程启动后立即退出」，
/// 于是把一段与真实原因无关的提示（0xC0000005 / 杀毒拦截）甩给用户 —— 用户
/// 永远不知道该做什么。正确做法只有一条：**以管理员身份重启**（UAC），
/// 重启后 TUN 才能建起来。
///
/// macOS 同理需要 root（创建 utun + 改路由）。本类只做检测与提示用信息，
/// macOS 的提权重启需特权助手，暂不自动执行（见 [relaunchHint]）。
class Elevation {
  Elevation._();

  /// 测试注入：让单测能假定「已提权 / 未提权」，不受运行环境影响。
  @visibleForTesting
  static bool? debugElevatedOverride;

  /// 桌面端才有「提权后才有 TUN」的概念；移动端 VpnService / PacketTunnel
  /// 本身就是特权通道，恒为可用。
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 当前进程是否已具备 TUN 权限。
  static bool get isElevated {
    final override = debugElevatedOverride;
    if (override != null) return override;
    if (Platform.isWindows) return _isUserAnAdmin();
    if (Platform.isMacOS || Platform.isLinux) return _euid() == 0;
    return true;
  }

  /// 未提权时给用户的**可执行**指引（正文）。
  static String get relaunchHint => Platform.isWindows
      ? 'TUN 需要创建虚拟网卡并修改路由表，Windows 必须由管理员运行。'
          '点「以管理员身份重启」后重新连接即可；不想提权就用「智能/全局」'
          '模式（系统代理），网页与 App 一样能走代理。'
      : 'TUN 需要 root 权限创建 utun 网卡并修改路由表。macOS 上请改用'
          '「智能/全局」模式（系统代理），或从终端以 root 启动本应用。';

  // ---------------------------------------------------------------- Windows

  static bool _isUserAnAdmin() {
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final fn = shell32.lookupFunction<Int32 Function(), int Function()>(
          'IsUserAnAdmin');
      return fn() != 0;
    } catch (e) {
      // 拿不到就按「未提权」处理：TUN 会失败，但提示是安全的（引导兜底路径）
      AppLog.log('APP', 'IsUserAnAdmin 探测失败: $e');
      return false;
    }
  }

  /// **以管理员身份重启**（Windows）。
  ///
  /// 实现要点：
  ///  - 用 UAC 的 `runas` 动词拉新进程（[Windows] `ShellExecuteW`），失败
  ///    （用户点了「否」）返回 false，调用方不要退出，避免把用户关在门外；
  ///  - 新实例启动时会抢 Windows 命名互斥量（`windows/runner/main.cpp` 的
  ///    CreateMutexW），旧进程还活着就会被判成「重复启动」而自杀。因此这里
  ///    不直接拉起，而是交给一个**脱离父进程**的 PowerShell 延迟 1.5s 再启动
  ///    —— 调用方随后立刻 `exit(0)`，等新实例起来时互斥量已经释放。
  ///
  /// 返回 true = 已安排重启（调用方应尽快退出进程）。
  static Future<bool> relaunchElevated() async {
    if (!Platform.isWindows) return false;
    final exe = Platform.resolvedExecutable;
    // PowerShell 单引号字符串里把单引号转义成两个单引号
    final quoted = exe.replaceAll("'", "''");
    // --admin-restart-for-tun：告诉新实例「你是来接替旧进程的」，让它跳过
    // 单实例互斥量检查（旧进程退出通常要 1~3s，只靠延迟会偶发被挡回去）。
    final script = 'Start-Sleep -Milliseconds 1500; '
        "Start-Process -FilePath '$quoted' -ArgumentList '--admin-restart-for-tun' -Verb RunAs";
    try {
      await Process.start(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', script],
        mode: ProcessStartMode.detached,
      );
      AppLog.log('APP', '已安排以管理员身份重启: $exe');
      return true;
    } catch (e) {
      AppLog.error('以管理员身份重启失败: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------- POSIX

  static int _euid() {
    try {
      final fn = DynamicLibrary.process()
          .lookupFunction<Uint32 Function(), int Function()>('geteuid');
      return fn();
    } catch (_) {
      return -1;
    }
  }
}
