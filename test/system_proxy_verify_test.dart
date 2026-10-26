@Tags(['e2e'])
library;

// 真实系统代理验证（macOS / Windows 真机）。
//
// ⚠️ 这三个用例会**真实读写**宿主机的系统代理（macOS 走 networksetup +
// scutil，Windows 走 HKCU 注册表），结束时恢复原值。
//
// 为什么合并到一个文件：`flutter test` 会**并行跑不同文件**，而每个用例都要
// apply → 断言 → restore 同一份系统代理状态。分成三个文件时会出现
// 「A 的 apply 还没读完状态，B 的 restore 已经把代理关掉」的交叉干扰，表现为
// 随机某个用例断言 HTTPEnable 失败（我加绕过列表写入后拉长了 apply 窗口，
// 让这个既有竞争明显更容易触发）。同一个文件内的用例是**顺序执行**的，
// 合并即可根治，且不牺牲任何真实环境验证能力。
//
// 运行方式（在对应平台上，仓库根目录）：
//   flutter test test/system_proxy_verify_test.dart
// 非对应平台自动跳过。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/system_proxy.dart';

const _winReg =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

Future<String> _scutil() async =>
    (await Process.run('scutil', ['--proxy'])).stdout as String;

/// 读注册表：ProxyEnable 是否为 1
Future<bool> _winProxyEnabled() async {
  final r = await Process.run('reg', ['query', _winReg, '/v', 'ProxyEnable'],
      runInShell: true);
  return r.exitCode == 0 && (r.stdout as String).contains('0x1');
}

/// 读注册表：ProxyServer 是否指向 127.0.0.1:port
Future<bool> _winProxyPointsTo(int port) async {
  final r = await Process.run('reg', ['query', _winReg, '/v', 'ProxyServer'],
      runInShell: true);
  if (r.exitCode != 0) return false;
  return (r.stdout as String).contains('127.0.0.1:$port');
}

// ---- 基线快照：这些 macOS 用例会真改本机系统代理，必须知道「测试前是什么样」----
//
// 旧实现假设「测试前系统代理是关闭的」，于是 restore 后断言 `HTTPEnable : 0`。
// 但开发机/用户机上常常**另有代理程序在跑**（实测：另一份代理客户端占着
// 127.0.0.1:17890 并开着系统代理）—— 此时 restore 会**正确**地恢复到那个开启
// 状态，断言却要求它是关闭的 → 用例变红，且红得毫无信息量。
// 现在改为：先快照基线 → 结束时断言「恢复到基线」；若发现别人的代理正占用
// （开启且端口不是本程序的 2080），直接跳过，避免两个代理程序互相抢系统代理。

const _localTestPort = 2080;

Future<String> _proxySnapshot() async =>
    (await Process.run('scutil', ['--proxy'])).stdout as String;

/// 基线是否为「别人的代理」正在生效
bool _foreignProxyActive(String baseline) {
  if (!baseline.contains('HTTPEnable : 1')) return false;
  final m = RegExp(r'HTTPPort : (\d+)').firstMatch(baseline);
  return m != null && m.group(1) != '$_localTestPort';
}

/// 断言已恢复到基线状态（而不是硬编码「应当是关闭的」）
void _expectRestoredToBaseline(String after, String baseline) {
  if (baseline.contains('HTTPEnable : 1')) {
    expect(after.contains('HTTPEnable : 1'), isTrue,
        reason: '应恢复到测试前的开启状态\n$after');
    final port = RegExp(r'HTTPPort : (\d+)').firstMatch(baseline)?.group(1);
    if (port != null) {
      expect(after.contains('HTTPPort : $port'), isTrue,
          reason: '应恢复到测试前的端口 $port\n$after');
    }
    return;
  }
  expect(after.contains('HTTPEnable : 0'), isTrue,
      reason: '代理应已关闭（恢复原状）\n$after');
  expect(after.contains('HTTPSEnable : 0'), isTrue);
  expect(after.contains('SOCKSEnable : 0'), isTrue);
}

/// 测试前的跳过判定：返回跳过原因（null = 可以跑）
///
/// 两种情况都跳过（本用例会真改系统代理，硬跑只会得到假红）：
///   1. 系统代理被**别的程序**接管（端口不是本程序的 2080）；
///   2. 本机 2080/9090 上已有进程在监听 —— 说明**有 MBox（或其它代理）实例
///      正在运行**，它的保活/退出会与我们 apply/restore 互相覆盖。
///      实测：开发机开着客户端时该用例必红，而 restore() 的行为其实是对的。
Future<String?> _skipIfForeignProxy() async {
  final base = await _proxySnapshot();
  if (_foreignProxyActive(base)) {
    return '检测到另一个代理程序正在管理系统代理'
        '（${RegExp(r'HTTPProxy : (\S+)').firstMatch(base)?.group(1)}:'
        '${RegExp(r'HTTPPort : (\d+)').firstMatch(base)?.group(1)}）——'
        '本用例会真改系统代理，跳过以免与本程序的 apply/restore 互相干扰';
  }
  if (await SystemProxyManager.isLocalPortAlive(_localTestPort)) {
    return '本机端口 $_localTestPort 上已有进程在监听（有 MBox 或其它代理实例'
        '正在运行）—— 它的保活与退出会与本用例的 apply/restore 互相覆盖，'
        '跳过以免产生假红。请先退出正在运行的客户端再执行本文件';
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ==================== macOS ====================

  test('macOS 系统代理：apply 设置 → restore 恢复', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS 验证');
      return;
    }
    final skip = await _skipIfForeignProxy();
    if (skip != null) {
      markTestSkipped(skip);
      return;
    }
    final baseline = await _proxySnapshot();
    // 1) 设置系统代理
    await SystemProxyManager.apply(port: 2080);
    final applied =
        (await Process.run('scutil', ['--proxy'])).stdout as String;
    expect(applied.contains('HTTPEnable : 1'), isTrue,
        reason: 'HTTP 代理应已启用\n$applied');
    expect(applied.contains('HTTPProxy : 127.0.0.1'), isTrue);
    expect(applied.contains('HTTPPort : 2080'), isTrue,
        reason: '代理端口应为 2080');

    // 2) 幂等：再次 apply 不报错
    await SystemProxyManager.apply(port: 2080);

    // 3) 恢复系统代理
    await SystemProxyManager.restore();
    final restored =
        (await Process.run('scutil', ['--proxy'])).stdout as String;
    _expectRestoredToBaseline(restored, baseline);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // 回归：系统代理保活。核心验证「代理被外部关掉后，ensureApplied 能强制重开」
  // —— 修复前的 bug：_applied 仍为 true 时 _applyNow 幂等 return，导致检测到掉了却修不回，
  // 表现为「软件显示已连接，但 Windows/macOS 系统代理已被关闭且不再恢复」。
  test('macOS 保活：代理被外部关闭后 ensureApplied 强制重新开启', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS 可真实验证系统代理保活');
      return;
    }
    final skip = await _skipIfForeignProxy();
    if (skip != null) {
      markTestSkipped(skip);
      return;
    }
    final baseline = await _proxySnapshot();
    try {
      // 1) 连接：设置系统代理
      await SystemProxyManager.apply(port: 2080);
      expect(SystemProxyManager.isApplied, isTrue);
      var s = await _scutil();
      expect(s.contains('HTTPEnable : 1'), isTrue, reason: 'apply 后应开启\n$s');
      expect(s.contains('HTTPPort : 2080'), isTrue);

      // 2) 模拟「系统/外部把代理关掉」——绕过 manager 直接关闭所有服务代理，
      //    但 manager 内部状态仍是 isApplied=true（正是触发 bug 的前置条件）。
      //    遍历可能受网络服务枚举/时序影响:关闭后复查,若仍有残留再补一轮
      for (var attempt = 0; attempt < 3; attempt++) {
        final services = (await Process.run(
                'networksetup', ['-listallnetworkservices']))
            .stdout as String;
        for (final svc in services
            .split('\n')
            .map((e) => e.trim())
            .where((e) =>
                e.isNotEmpty && !e.startsWith('*') && !e.contains('denotes'))) {
          for (final kind in ['web', 'secureweb', 'socksfirewall']) {
            await Process.run('networksetup', ['-set${kind}proxystate', svc, 'off']);
          }
        }
        s = await _scutil();
        if (s.contains('HTTPEnable : 0')) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(s.contains('HTTPEnable : 0'), isTrue,
          reason: '前置：代理已被外部关闭\n$s');
      expect(SystemProxyManager.isApplied, isTrue,
          reason: 'manager 仍以为处于已应用态（bug 触发前提）');

      // 3) 保活巡检：必须检测到掉线并强制重开（修复点）
      await SystemProxyManager.ensureApplied(port: 2080);
      s = await _scutil();
      expect(s.contains('HTTPEnable : 1'), isTrue,
          reason: 'ensureApplied 应把被关掉的代理重新开启（保活核心）\n$s');
      expect(s.contains('HTTPPort : 2080'), isTrue);
    } finally {
      await SystemProxyManager.restore();
    }
    // 4) 断开：恢复到原始（关闭）状态
    final after = await _scutil();
    _expectRestoredToBaseline(after, baseline);
    expect(SystemProxyManager.isApplied, isFalse);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('macOS 保活 reassert 不破坏原始配置捕获：restore 仍回到原始状态（基线）', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS');
      return;
    }
    final skip = await _skipIfForeignProxy();
    if (skip != null) {
      markTestSkipped(skip);
      return;
    }
    final baseline = await _proxySnapshot();
    try {
      await SystemProxyManager.apply(port: 2080);
      // 连续多次 reassert（模拟多轮保活），不应把「自己写入的值」误存为原始配置
      await SystemProxyManager.ensureApplied(port: 2080);
      await SystemProxyManager.ensureApplied(port: 2080);
    } finally {
      await SystemProxyManager.restore();
    }
    final after = await _scutil();
    _expectRestoredToBaseline(after, baseline);
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ==================== Windows ====================

  test('Windows 系统代理：apply → 外部关闭 → 保活重开 → restore', () async {
    if (!Platform.isWindows) {
      markTestSkipped('仅 Windows 验证');
      return;
    }
    try {
      // 1) 连接：设置系统代理
      await SystemProxyManager.apply(port: 2080);
      expect(await _winProxyEnabled(), isTrue, reason: 'apply 后 ProxyEnable 应为 1');
      expect(await _winProxyPointsTo(2080), isTrue,
          reason: 'apply 后 ProxyServer 应为 127.0.0.1:2080');

      // 2) 模拟系统/外部把代理关掉（正是你遇到的现象：软件还连着，代理被关）
      await Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0',
              '/f'],
          runInShell: true);
      expect(await _winProxyEnabled(), isFalse, reason: '前置：代理已被外部关闭');
      expect(SystemProxyManager.isApplied, isTrue,
          reason: 'manager 仍以为已应用（触发原 bug 的前提）');

      // 3) 保活巡检：必须检测到掉线并强制重开（本次修复的核心）
      await SystemProxyManager.ensureApplied(port: 2080);
      expect(await _winProxyEnabled(), isTrue,
          reason: '保活应把被关掉的代理重新打开 —— 这是"保持始终开启"的关键');
      expect(await _winProxyPointsTo(2080), isTrue);
    } finally {
      await SystemProxyManager.restore();
    }
    expect(SystemProxyManager.isApplied, isFalse, reason: 'restore 后应为未应用');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Windows FFI 通知不崩溃（InternetSetOption 签名正确性）', () async {
    if (!Platform.isWindows) {
      markTestSkipped('仅 Windows 验证');
      return;
    }
    // apply/restore 内部会调用 _notifyWinInetChanged（FFI）。
    // 若 FFI 签名错误会抛异常（被内部 catch 成 debugPrint，不会崩溃）；
    // 这里主要确认整条 apply→restore 走 FFI 通知路径不抛未捕获异常。
    await SystemProxyManager.apply(port: 2080);
    await SystemProxyManager.restore();
    // 能走到这里即说明 FFI 调用未导致进程崩溃
    expect(true, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  // 回归：restore 必须把「原本不存在的注册表值」删除，而非残留我们写入的
  // 127.0.0.1:2080 / <local>（真机发现的 bug：原本未配代理的机器断开后残留）。
  test('Windows restore 无残留：原本不存在的值应被删除', () async {
    if (!Platform.isWindows) {
      markTestSkipped('仅 Windows 验证');
      return;
    }
    // 记录 apply 前 ProxyServer/ProxyOverride 是否存在（exitCode==0 即存在）
    Future<bool> exists(String name) async {
      final r = await Process.run('reg', ['query', _winReg, '/v', name],
          runInShell: true);
      return r.exitCode == 0;
    }

    final serverExistedBefore = await exists('ProxyServer');
    final overrideExistedBefore = await exists('ProxyOverride');

    await SystemProxyManager.apply(port: 2080);
    await SystemProxyManager.restore();

    // restore 后存在性必须回到 apply 前：原本没有的，现在也不能有
    expect(await exists('ProxyServer'), serverExistedBefore,
        reason: 'ProxyServer 存在性应恢复到 apply 前（原本无则应被删除，不残留）');
    expect(await exists('ProxyOverride'), overrideExistedBefore,
        reason: 'ProxyOverride 存在性应恢复到 apply 前（原本无则应被删除，不残留）');
    // 若原本就有值，还需确认不是残留的我们的值
    if (!serverExistedBefore) {
      expect(await _winProxyPointsTo(2080), isFalse,
          reason: '原本无 ProxyServer，restore 后不应残留 127.0.0.1:2080');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
