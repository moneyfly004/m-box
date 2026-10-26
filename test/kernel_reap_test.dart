// 残留内核收割策略：只收真孤儿，绝不杀别的实例正在用的活内核。
//
// 背景（2026-09-14 真实日志）：三次快速启动产生多实例，新实例的启动清扫
// 对「命令行含 mbox_core 的所有 sing-box」无条件 Stop-Process，把 17:09
// 那个实例正在用的内核杀了（PowerShell 终止码 -1，与日志完全吻合），随后
// 因 autoReconnect 默认关闭不再恢复 —— 用户看到的是「好好的突然断线」。
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';

bool _stale({
  int pid = 100,
  int? parentPid = 50,
  bool parentAlive = false,
  bool parentIsApp = false,
  int? livePid,
}) =>
    ProxyCoreCli.isStaleKernelCandidate(
      pid: pid,
      parentPid: parentPid,
      parentAlive: parentAlive,
      parentIsApp: parentIsApp,
      livePid: livePid,
    );

void main() {
  group('isStaleKernelCandidate', () {
    test('父进程已消失 → 真孤儿，可收（上次 App 被强杀留下的）', () {
      expect(_stale(parentAlive: false), isTrue);
    });

    test('父进程是活着的 MBox → 别的实例在用，绝不收（核心回归）', () {
      expect(_stale(parentAlive: true, parentIsApp: true), isFalse);
    });

    test('父进程活着但不是本 App（PID 被复用）→ 按残留收掉，否则端口锁永远解不开', () {
      expect(_stale(parentAlive: true, parentIsApp: false), isTrue);
    });

    test('拿不到 ppid → 视为孤儿', () {
      expect(_stale(parentPid: null), isTrue);
    });

    test('pid<=1 绝不碰（内核线程 / init）', () {
      expect(_stale(pid: 1), isFalse);
      expect(_stale(pid: 0), isFalse);
    });

    test('livePid 豁免：本实例当前跟踪的内核永不自杀', () {
      expect(_stale(pid: 100, livePid: 100), isFalse);
      // 其它孤儿仍可正常收割
      expect(_stale(pid: 101, livePid: 100), isTrue);
    });
  });
}
