@Tags(['e2e'])
library;

// 残留内核收割的**真实进程**验证（POSIX）。
//
// 纯逻辑单测（kernel_reap_test.dart）只能证明判定函数对；这里用真进程证明
// 「活实例的内核不会被误杀、真孤儿一定会被收」——2026-09-14 的故障就是
// 后者被前者误伤（新实例把 17:09 实例正在跑的内核杀了，退出码 -1）。
//
// 造两个假进程：
//   mbox_fake_app      —— 命令行含 mbox 的「活着的 App」
//   sing-box_mbox_core —— 命令行含 sing-box + mbox_core 的「内核」
// 前者是后者的父进程，复刻真实父子关系。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';

/// 进程是否存活
Future<bool> _alive(int pid) async {
  final r = await Process.run('ps', ['-p', '$pid', '-o', 'pid=']);
  return (r.stdout as String).trim().isNotEmpty;
}

Future<void> _waitGone(int pid, {int ms = 2000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(deadline)) {
    if (!await _alive(pid)) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

/// 起一个「假 App + 假内核」进程组，返回 (appPid, kernelPid)
Future<({int appPid, int kernelPid})> _spawnFakePair(Directory tmp) async {
  final script = File('${tmp.path}/fake_pair.sh');
  await script.writeAsString('''
exec -a mbox_fake_app bash -c '
  exec -a sing-box_mbox_core sleep 300 &
  echo "\$!"
  wait
'
''');
  final proc = await Process.start('bash', [script.path]);
  final kernelPid =
      int.parse((await proc.stdout.transform(const SystemEncoding().decoder).first).trim());
  // 父进程（假 App）pid 就是 proc.pid（exec -a 只改名，不换 pid）
  return (appPid: proc.pid, kernelPid: kernelPid);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final isPosix = Platform.isMacOS || Platform.isLinux;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mf_reap_e2e');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('活实例的内核不被误杀；父进程死后成为真孤儿 → 被收掉', () async {
    final pair = await _spawnFakePair(tmp);
    addTearDown(() async {
      // 兜底清理，避免测试失败时留下 sleep 300
      for (final pid in [pair.kernelPid, pair.appPid]) {
        try {
          Process.killPid(pid, ProcessSignal.sigkill);
        } catch (_) {}
      }
    });

    expect(await _alive(pair.kernelPid), isTrue, reason: '假内核没起来');

    // ① 父进程（假 App）活着 → 这是「另一个实例正在用的内核」，清扫必须放过它
    await ProxyCoreCli.killStaleKernels();
    expect(await _alive(pair.kernelPid), isTrue,
        reason: '活实例的内核被误杀了 —— 这正是 2026-09-14 的故障');

    // ② 父进程被强杀（模拟 App 崩溃/被任务管理器结束）→ 内核成为孤儿
    Process.killPid(pair.appPid, ProcessSignal.sigkill);
    await _waitGone(pair.appPid);
    expect(await _alive(pair.appPid), isFalse);

    // ③ 此时才是该收的残留：否则它会占着 2080/9090 与 cache.db 锁，
    //    表现为「退出后重开连不上」
    await ProxyCoreCli.killStaleKernels();
    await _waitGone(pair.kernelPid);
    expect(await _alive(pair.kernelPid), isFalse,
        reason: '真孤儿没被回收 —— 端口/缓存锁会被一直占着');
  }, skip: isPosix ? null : '仅 POSIX（macOS/Linux）验证');
}
