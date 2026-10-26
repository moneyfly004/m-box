/// 本地端口占用：检测、自愈与可执行报错。
///
/// ## 为什么需要这个文件
/// 内核启动失败最典型的一种是：
/// ```
/// FATAL[0000] start service: start inbound: start inbound/mixed[mixed-in]:
///   listen tcp 127.0.0.1:2080: bind: address already in use
/// ```
/// 旧实现只会把内核这一大段 FATAL 原样塞进错误提示（用户根本读不懂），而且
/// **没有任何自救**：端口被谁占着、能不能自动腾出来、要不要换端口 —— 全靠用户猜。
///
/// 而 `[ProxyCoreCli.killStaleKernels]` 只收「父进程已经消失」的真孤儿；下面两类
/// 它按设计不会动，于是端口被长期占着、连接一直失败：
/// 1. 上一版/另一个 App 实例留下的内核（父进程还活着）；
/// 2. 桌面端的**测速探测内核**（`moneyfly_probe`）。
///
/// 本文件把这件事变成确定性的三步：
/// **探活（bind 探测）→ 占用者是谁（lsof/ps）→ 我方残留就杀掉并等端口释放，
/// 别人的程序就抛类型化错误（带进程名 + PID），由 UI 给「换端口并重连」。**
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../l10n/app_strings.dart';
import '../services/app_log.dart';
import 'conn_error.dart';

/// 占用某个本地端口的进程。
class PortHolder {
  const PortHolder({required this.pid, required this.command});

  final int pid;

  /// 完整命令行（用于判定「是不是我们自己的内核」）
  final String command;

  /// 是不是**本 App 自己的内核**（残留 / 孤儿 / 探测内核 / 另一实例的内核）。
  ///
  /// 判据故意写得很窄 —— **宁可判成「别人的程序」也绝不误杀别的代理软件**：
  /// - 我们的内核工作目录名会出现在 `-c/-D` 参数里：`moneyfly_core` /
  ///   `moneyfly_probe`；
  /// - 或者就是 App 包内自带的那个 `sing-box` 二进制。
  bool get isOurKernel {
    final c = command;
    if (c.isEmpty) return false;
    return c.contains('moneyfly_core') ||
        c.contains('moneyfly_probe') ||
        c.contains('/Contents/MacOS/sing-box');
  }

  /// 展示用短描述：可执行文件名 + PID（整条命令行太长，塞进错误提示没法看）。
  String get describe {
    final first = command.trim().split(RegExp(r'\s+')).first;
    if (first.isEmpty) return 'PID $pid';
    final name = first.split('/').last;
    return '$name（PID $pid）';
  }

  @override
  String toString() => 'PortHolder(pid=$pid, command=$command)';
}

/// 端口占用检测 / 自愈（纯逻辑，IO 走 [dart:io]，可注入桩做单测）。
class PortGuard {
  PortGuard._();

  /// 测试注入：非空时替代真实 bind 探测。
  @visibleForTesting
  static Future<bool> Function(int port)? debugIsFree;

  /// 测试注入：非空时替代真实 lsof/ps 查询。
  @visibleForTesting
  static Future<PortHolder?> Function(int port)? debugWhoListens;

  /// 测试注入：非空时替代真实 SIGKILL。
  @visibleForTesting
  static Future<bool> Function(int pid)? debugKill;

  /// 测试注入：非空时替代真实 ppid 查询。
  @visibleForTesting
  static Future<int?> Function(int pid)? debugParentPid;

  /// 端口是否空闲。
  ///
  /// 用 **bind 探测**而不是 connect 探测，判据与内核完全一致：内核起不来正是
  /// 因为这个 bind 会失败。connect 成功只能说明「有人在听」，两者不等价
  /// （例如对方只监听 0.0.0.0 或用了 SO_REUSEADDR 时，connect 成功但内核仍能
  /// 正常 bind；反过来 TIME_WAIT/半开连接也会让 bind 失败而 connect 失败）。
  static Future<bool> isFree(int port) async {
    final probe = debugIsFree;
    if (probe != null) return probe(port);
    if (port < 1 || port > 65535) return false;
    ServerSocket? s;
    try {
      // 与内核一致绑 127.0.0.1（回环）：别用 0.0.0.0 测，那会把
      // 「只绑了回环的内核」误判为空闲，反过来又制造假阳性。
      s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await s?.close();
      } catch (_) {}
    }
  }

  /// 谁在监听 [port]（null = 没人监听 / 查不到 / 平台没有 lsof）。
  ///
  /// macOS/Linux 用 `lsof -F pc` 拿 pid + 命令名，再用 `ps -o command=` 取**完整
  /// 命令行**（判定 isOurKernel 必须看参数里的工作目录）。Windows 没有 lsof →
  /// 返回 null：此时仍能靠 bind 探测判定「被占用」，只是提示里没有进程名。
  static Future<PortHolder?> whoListens(int port) async {
    final probe = debugWhoListens;
    if (probe != null) return probe(port);
    if (!(Platform.isMacOS || Platform.isLinux)) return null;
    if (port < 1 || port > 65535) return null;
    try {
      final r = await Process.run(
        'lsof',
        ['-nP', '-iTCP:$port', '-sTCP:LISTEN', '-F', 'pc'],
      ).timeout(const Duration(seconds: 3));
      final pids = parseLsofPids('${r.stdout}');
      if (pids.isEmpty) return null;
      // 多个监听者（极少见）：取第一个能读到命令行的
      for (final pid in pids) {
        final cmd = await _commandOf(pid);
        if (cmd.isNotEmpty) return PortHolder(pid: pid, command: cmd);
      }
      return PortHolder(pid: pids.first, command: '');
    } catch (_) {
      return null;
    }
  }

  /// 解析 `lsof -F pc` 的输出（`p<pid>` 与 `c<command>` 成对出现，按块划分）。
  ///
  /// 抽成纯函数便于单测：真实 lsof 输出随平台/版本变化，解析一错就会
  /// 「明明有占用者却报不出来」。
  @visibleForTesting
  static List<int> parseLsofPids(String out) {
    final pids = <int>[];
    for (final line in out.split('\n')) {
      final t = line.trim();
      if (t.length < 2 || !t.startsWith('p')) continue;
      final pid = int.tryParse(t.substring(1));
      if (pid != null && pid > 1 && !pids.contains(pid)) pids.add(pid);
    }
    return pids;
  }

  /// 内核日志里出现了「端口被占用」的致命串。
  ///
  /// 覆盖 macOS/Linux（`address already in use`）与 Windows（`Only one usage of
  /// each socket address ... is normally permitted`）。
  static bool looksLikePortInUse(String log) {
    final l = log.toLowerCase();
    return l.contains('address already in use') ||
        l.contains('only one usage of each socket address') ||
        l.contains('cannot assign requested address');
  }

  /// 从内核日志里抠出**真正绑失败的那个端口**（抠不到 → null）。
  ///
  /// sing-box 的 FATAL 形如 `listen tcp 127.0.0.1:2080: bind: ...`：
  /// 有了这个端口，报错才敢准确地说「2080 被谁占用」，而不是猜本地代理端口。
  static int? portFromLog(String log) {
    final m = RegExp(r'listen\s+(?:tcp|udp)\s+\S*?:(\d+)').firstMatch(log);
    if (m != null) {
      final p = int.tryParse(m.group(1) ?? '');
      if (p != null && p > 0 && p <= 65535) return p;
    }
    final m2 = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(log);
    final p2 = int.tryParse(m2?.group(1) ?? '');
    return (p2 != null && p2 > 0 && p2 <= 65535) ? p2 : null;
  }

  /// 杀掉占用者（仅用于**我们自己的残留内核**）。
  static Future<bool> killHolder(PortHolder h) async {
    final kill = debugKill;
    if (kill != null) return kill(h.pid);
    if (h.pid <= 1) return false;
    try {
      return Process.killPid(h.pid, ProcessSignal.sigkill);
    } catch (_) {
      return false;
    }
  }

  /// 等端口真的释放（默认 3s）。杀掉进程后内核要一点时间回收监听 socket，
  /// 立刻重试很可能又 bind 失败 —— 必须等「确实空了」而不是「刚发了 kill」。
  static Future<bool> waitFree(
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (await isFree(port)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return isFree(port);
  }

  /// 占用者能否**安全回收**（只回收我们自己的残留内核）。
  ///
  /// 判定与 `ProxyCoreCli.isStaleKernelCandidate` 同一套哲学，避免制造新故障：
  /// - 不是我方内核 → 不能杀（别的代理软件）；
  /// - 父进程已消失（孤儿，上次 App 被强杀留下的）→ 可回收；
  /// - 父进程**就是本 App**（我们弄丢跟踪的那个内核）→ 可回收；
  /// - 父进程是**另一个活着的 App 实例** → **不可**回收：杀了就是「好好的突然
  ///   断线」，只能提示用户先退出那个实例。
  static Future<bool> canReclaim(PortHolder h, {int? selfPid}) async {
    if (!h.isOurKernel) return false;
    final parent = await parentPidOf(h.pid);
    if (parent == null) return true; // 拿不到 ppid → 按孤儿处理（与旧逻辑一致）
    if (parent <= 1) return true; // launchd/init：真孤儿
    return parent == (selfPid ?? pid);
  }

  /// 取父进程 pid（拿不到 → null）。
  static Future<int?> parentPidOf(int p) async {
    final probe = debugParentPid;
    if (probe != null) return probe(p);
    if (p <= 1) return null;
    try {
      final r = await Process.run('ps', ['-o', 'ppid=', '-p', '$p'])
          .timeout(const Duration(seconds: 2));
      final raw = '${r.stdout}'.trim();
      return raw.isEmpty ? null : int.tryParse(raw.split(RegExp(r'\s+')).first);
    } catch (_) {
      return null;
    }
  }

  /// 启动内核前的端口预检（`bind: address already in use` 的根治点）。
  ///
  /// - 空闲 → 直接返回；
  /// - 占用者是**我们自己的残留内核** → SIGKILL 并等端口真正释放（用户无感自愈）；
  /// - 占用者是别的程序 / 另一个 App 实例的内核 / 收不掉 → 抛
  ///   [TypedConnError]（portInUse），文案带进程名 + PID，用户知道该关谁；
  ///   UI 另有「换端口并重连」按钮。
  static Future<void> ensureFree(int port, {required String what}) async {
    if (await isFree(port)) return;
    final holder = await whoListens(port);
    if (holder != null && holder.isOurKernel) {
      if (!await canReclaim(holder)) {
        // 另一个活着的 App 实例在用这个端口：绝不能杀（会断了它正在用的连接）
        throw TypedConnError(
          ConnErrorKind.portInUse,
          AppStrings.t('err_port_in_use_other_instance',
              {'what': what, 'port': '$port', 'holder': holder.describe}),
        );
      }
      AppLog.error(
          '[PORT] $what $port 被本 App 的残留内核占用（${holder.describe}），正在回收');
      await killHolder(holder);
      if (await waitFree(port)) {
        AppLog.log('PORT', '$what $port 已释放（回收残留内核 pid=${holder.pid}）');
        return;
      }
      AppLog.error('[PORT] $what $port 回收后仍未释放（${holder.describe}）');
    }
    throw TypedConnError(
      ConnErrorKind.portInUse,
      holder == null
          ? AppStrings.t('err_port_in_use_unknown', {'what': what, 'port': '$port'})
          : AppStrings.t('err_port_in_use',
              {'what': what, 'port': '$port', 'holder': holder.describe}),
    );
  }

  /// 挑一个空闲端口（[from] 起向上找 [span] 个，跳过 [avoid] 里的端口）。
  ///
  /// 找不到就退到系统分配的临时端口 —— **必须**返回一个能 bind 的端口，
  /// 否则「换端口并重连」这个自救按钮会变成第二个错误。
  static Future<int> pickFree({
    int from = 2080,
    Set<int> avoid = const {},
    int span = 60,
  }) async {
    final start = from.clamp(1024, 65535);
    for (var p = start; p < start + span && p <= 65535; p++) {
      if (avoid.contains(p)) continue;
      if (await isFree(p)) return p;
    }
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  /// 端口被占用时给用户的可展示文案（占用者未知 / 已知两种）。
  static Future<String> portInUseMessage(int port, {required String what}) async {
    final holder = await whoListens(port);
    return holder == null
        ? AppStrings.t('err_port_in_use_unknown', {'what': what, 'port': '$port'})
        : AppStrings.t('err_port_in_use',
            {'what': what, 'port': '$port', 'holder': holder.describe});
  }

  static Future<String> _commandOf(int pid) async {
    try {
      final r = await Process.run('ps', ['-o', 'command=', '-p', '$pid'])
          .timeout(const Duration(seconds: 2));
      return '${r.stdout}'.trim();
    } catch (_) {
      return '';
    }
  }
}
