// 端口占用：检测 / 占用者判定 / 自愈 / 可执行报错。
//
// 守卫的是线上真实故障（`listen tcp 127.0.0.1:2080: bind: address already in use`
// 连续 7 次、连接彻底不可用）背后的三件事：
//   1) 占用者到底是谁 —— 判定必须窄（只认我们自己的内核），绝不误杀其它代理软件；
//   2) 我们自己的残留内核要能自愈（杀掉 + 等端口真的释放），用户无感；
//   3) 别人的程序占着 → 抛类型化错误，文案带进程名/PID，UI 才有「换端口并重连」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mbox/core/proxy/conn_error.dart';
import 'package:mbox/core/proxy/port_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PortGuard.debugIsFree = null;
    PortGuard.debugWhoListens = null;
    PortGuard.debugKill = null;
    PortGuard.debugParentPid = null;
  });

  group('占用者判定（PortHolder.isOurKernel 必须窄）', () {
    test('我们自己的内核（连接内核 / 测速探测内核）→ 认作我方', () {
      expect(
          const PortHolder(
                  pid: 1,
                  command:
                      '/Applications/MBox.app/Contents/MacOS/sing-box run '
                      '-c /tmp/mbox_core/config.json -D /tmp/mbox_core')
              .isOurKernel,
          isTrue);
      expect(
          const PortHolder(
                  pid: 2,
                  command:
                      '/Applications/MBox.app/Contents/MacOS/sing-box run '
                      '-c /tmp/mbox_probe/config.json -D /tmp/mbox_probe')
              .isOurKernel,
          isTrue);
      // 只有包内二进制路径、没有工作目录参数（旧版内核）也要认出来
      expect(
          const PortHolder(
                  pid: 3, command: '/Applications/MBox.app/Contents/MacOS/sing-box')
              .isOurKernel,
          isTrue);
    });

    test('别的代理软件 / 系统进程 → **绝不**当作我方（不能误杀别人的程序）', () {
      expect(
          const PortHolder(pid: 10, command: 'ClashX Pro --port 2080').isOurKernel,
          isFalse);
      expect(
          const PortHolder(pid: 11, command: 'surge -l 2080').isOurKernel, isFalse);
      expect(
          const PortHolder(pid: 12, command: '/usr/bin/python3 -m http.server 2080')
              .isOurKernel,
          isFalse);
      // 只是「别人也跑 sing-box」：没有我们的 workDir 标记 → 不是我方
      expect(
          const PortHolder(pid: 13, command: 'sing-box run -c /tmp/th.json')
              .isOurKernel,
          isFalse);
      expect(const PortHolder(pid: 14, command: '').isOurKernel, isFalse);
    });

    test('展示文案只取可执行名 + PID（整条命令行不能塞进错误提示）', () {
      const h = PortHolder(pid: 80160, command: '/Applications/MBox.app/Contents/MacOS/sing-box run -c /x');
      expect(h.describe, 'sing-box（PID 80160）');
      expect(const PortHolder(pid: 7, command: '').describe, 'PID 7');
    });
  });

  group('日志解析', () {
    test('lsof -F pc 输出 → pid 列表（p<pid> / c<comm> 成对）', () {
      const out = 'p80160\ncsing-box\np43595\ncMBox\n';
      expect(PortGuard.parseLsofPids(out), [80160, 43595]);
      // 噪声行 / 非法 pid 不能被当成占用者
      expect(PortGuard.parseLsofPids('p\ncfoo\npx\np0\np1\n'), isEmpty);
      expect(PortGuard.parseLsofPids(''), isEmpty);
    });

    test('内核日志里的「端口被占用」致命串（mac/win 两种写法）', () {
      expect(
          PortGuard.looksLikePortInUse(
              'FATAL[0000] listen tcp 127.0.0.1:2080: bind: address already in use'),
          isTrue);
      expect(
          PortGuard.looksLikePortInUse(
              'bind: Only one usage of each socket address is normally permitted'),
          isTrue);
      // 普通失败（证书/协议错误）不能被误判成端口问题
      expect(
          PortGuard.looksLikePortInUse(
              'FATAL decode config: unknown transport type: xhttp'),
          isFalse);
      expect(PortGuard.looksLikePortInUse(''), isFalse);
    });

    test('从 FATAL 里抠出真正失败的端口（不是猜本地代理端口）', () {
      expect(
          PortGuard.portFromLog(
              'FATAL[0000] listen tcp 127.0.0.1:2080: bind: address already in use'),
          2080);
      expect(PortGuard.portFromLog('listen tcp 127.0.0.1:9090: bind: in use'), 9090);
      // 没有 listen 行时退回地址里的端口
      expect(PortGuard.portFromLog('dial 127.0.0.1:9091 failed'), 9091);
      expect(PortGuard.portFromLog('内核进程启动后立即退出'), isNull);
    });
  });

  group('真实 bind 探测（与内核同一判据）', () {
    test('被占用的端口 → 不空闲；释放后 → 空闲', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      expect(await PortGuard.isFree(port), isFalse,
          reason: '有人 listen 时必须判定为不空闲（内核起不来的同一判据）');
      await s.close();
      expect(await PortGuard.isFree(port), isTrue, reason: '释放后必须空闲');
    });

    test('非法端口一律视为不空闲（不能让内核去 bind 0/70000）', () async {
      expect(await PortGuard.isFree(0), isFalse);
      expect(await PortGuard.isFree(70000), isFalse);
    });
  });

  group('pickFree：换端口自救不能挑到新的冲突', () {
    test('跳过被占用端口与 avoid 集合', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => busy.close());
      final p = await PortGuard.pickFree(from: busy.port, avoid: {busy.port + 2});
      expect(p, isNot(busy.port), reason: '不能挑到正被占用的端口');
      expect(p, isNot(busy.port + 2), reason: '不能挑到 avoid 里的端口');
      expect(await PortGuard.isFree(p), isTrue);
    });
  });

  group('canReclaim：只回收真正的残留（别断另一个实例的连接）', () {
    test('不是我方内核 → 永不回收', () async {
      PortGuard.debugParentPid = (_) async => 1;
      expect(
          await PortGuard.canReclaim(
              const PortHolder(pid: 5, command: 'ClashX --port 2080')),
          isFalse);
    });

    test('我方内核 + 父进程已消失/是 launchd → 可回收（真孤儿）', () async {
      const h = PortHolder(pid: 5, command: 'sing-box run -D /tmp/mbox_core');
      PortGuard.debugParentPid = (_) async => 1;
      expect(await PortGuard.canReclaim(h), isTrue);
      PortGuard.debugParentPid = (_) async => null; // 拿不到 ppid
      expect(await PortGuard.canReclaim(h), isTrue);
    });

    test('我方内核 + 父进程就是本 App → 可回收（我们弄丢跟踪的那个）', () async {
      const h = PortHolder(pid: 5, command: 'sing-box run -D /tmp/mbox_core');
      PortGuard.debugParentPid = (_) async => 4242;
      expect(await PortGuard.canReclaim(h, selfPid: 4242), isTrue);
    });

    test('我方内核 + 父进程是**另一个活着的 App 实例** → 不可回收', () async {
      const h = PortHolder(pid: 5, command: 'sing-box run -D /tmp/mbox_core');
      PortGuard.debugParentPid = (_) async => 9999;
      expect(await PortGuard.canReclaim(h, selfPid: 4242), isFalse,
          reason: '杀了另一个实例的内核 = 让它「好好的突然断线」');
    });
  });

  group('ensureFree：启动内核前的确定性处理', () {
    test('端口空闲 → 直接通过，不查占用者、不杀任何进程', () async {
      var killed = 0;
      PortGuard.debugIsFree = (_) async => true;
      PortGuard.debugWhoListens = (_) async => fail('空闲时不该去查占用者');
      PortGuard.debugKill = (_) async {
        killed++;
        return true;
      };
      await PortGuard.ensureFree(2080, what: '本地代理端口');
      expect(killed, 0);
    });

    test('占用者是**我方残留内核** → 杀掉并等端口释放（用户无感自愈）', () async {
      var freed = false;
      final killedPids = <int>[];
      PortGuard.debugIsFree = (_) async => freed;
      PortGuard.debugWhoListens = (_) async => const PortHolder(
          pid: 80160,
          command:
              '/Applications/MBox.app/Contents/MacOS/sing-box run -D /tmp/mbox_core');
      PortGuard.debugParentPid = (_) async => 1; // 孤儿
      PortGuard.debugKill = (pid) async {
        killedPids.add(pid);
        freed = true; // 杀掉后端口释放
        return true;
      };
      await PortGuard.ensureFree(2080, what: '本地代理端口');
      expect(killedPids, [80160], reason: '残留内核必须被回收，否则连接永远起不来');
    });

    test('占用者是别的程序 → 抛 portInUse，文案带进程名 + PID（用户知道该关谁）', () async {
      var killed = 0;
      PortGuard.debugIsFree = (_) async => false;
      PortGuard.debugWhoListens = (_) async =>
          const PortHolder(pid: 4321, command: '/Applications/ClashX.app/ClashX --port 2080');
      PortGuard.debugKill = (_) async {
        killed++;
        return true;
      };
      await expectLater(
        () => PortGuard.ensureFree(2080, what: '本地代理端口'),
        throwsA(isA<TypedConnError>()
            .having((e) => e.kind, 'kind', ConnErrorKind.portInUse)
            .having((e) => e.message, 'message', contains('ClashX'))
            .having((e) => e.message, 'message', contains('4321'))
            .having((e) => e.message, 'message', contains('2080'))),
      );
      expect(killed, 0, reason: '别人的程序绝不杀 —— 只提示用户');
    });

    test('查不到占用者（无 lsof / 权限不足）→ 仍然抛 portInUse，提示「其它程序占用」', () async {
      PortGuard.debugIsFree = (_) async => false;
      PortGuard.debugWhoListens = (_) async => null;
      await expectLater(
        () => PortGuard.ensureFree(9090, what: 'Clash API 端口'),
        throwsA(isA<TypedConnError>()
            .having((e) => e.kind, 'kind', ConnErrorKind.portInUse)
            .having((e) => e.message, 'message', contains('9090'))
            .having((e) => e.message, 'message', contains('换端口并重连'))),
      );
    });

    test('我方残留内核杀不掉 → 如实报错（绝不假装端口已腾出来继续启动）', () async {
      PortGuard.debugIsFree = (_) async => false;
      PortGuard.debugWhoListens = (_) async =>
          const PortHolder(pid: 99, command: 'sing-box run -D /tmp/mbox_core');
      PortGuard.debugParentPid = (_) async => 1;
      PortGuard.debugKill = (_) async => false; // 权限不足/进程杀不掉
      await expectLater(
        () => PortGuard.ensureFree(2080, what: '本地代理端口'),
        throwsA(isA<TypedConnError>()
            .having((e) => e.kind, 'kind', ConnErrorKind.portInUse)),
      );
    });
  });

  group('ensureFree：另一个 App 实例占着端口', () {
    test('抛 portInUse（文案指向「另一个实例」）且**绝不杀**它', () async {
      var killed = 0;
      PortGuard.debugIsFree = (_) async => false;
      PortGuard.debugWhoListens = (_) async =>
          const PortHolder(pid: 777, command: 'sing-box run -D /tmp/mbox_core');
      PortGuard.debugParentPid = (_) async => 888; // 另一个活着的 App 实例
      PortGuard.debugKill = (_) async {
        killed++;
        return true;
      };
      await expectLater(
        () => PortGuard.ensureFree(2080, what: '本地代理端口'),
        throwsA(isA<TypedConnError>()
            .having((e) => e.kind, 'kind', ConnErrorKind.portInUse)
            .having((e) => e.message, 'message', contains('另一个 MBox 实例'))
            .having((e) => e.message, 'message', contains('777'))),
      );
      expect(killed, 0, reason: '另一个实例的内核不能杀');
    });
  });

  group('waitFree', () {
    test('端口释放后返回 true', () async {
      var freed = false;
      PortGuard.debugIsFree = (_) async => freed;
      Future<void>.delayed(const Duration(milliseconds: 150), () => freed = true);
      expect(await PortGuard.waitFree(2080, timeout: const Duration(seconds: 2)),
          isTrue);
    });

    test('一直不释放 → 超时返回 false（不无限等）', () async {
      PortGuard.debugIsFree = (_) async => false;
      final sw = Stopwatch()..start();
      expect(
          await PortGuard.waitFree(2080, timeout: const Duration(milliseconds: 300)),
          isFalse);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
