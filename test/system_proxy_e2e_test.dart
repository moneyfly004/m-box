@Tags(['e2e'])
library;

// 端到端：真实内核 + 系统代理管理（macOS 上验证「连接改变系统代理、断开恢复」）
//
// 内核位置：MBOX_SINGBOX / 仓库 .core_dl /
// build/sing-box / PATH；找不到时跳过（CI 桌面端不装内核二进制）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/singbox_config.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/core/services/local_paths.dart';

/// 定位本地 sing-box 内核（与 proxy_core_integration_test 同一套查找顺序）
String? _findBinary() {
  final injected = Platform.environment['MBOX_SINGBOX'];
  if (injected != null &&
      injected.isNotEmpty &&
      File(injected).existsSync()) {
    return injected;
  }
  final exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  final candidates = <String>[];
  for (final dir in [
    '${Directory.current.path}/.core_dl',
    '${Directory.current.path}/sing-box-bin',
    '${Directory.current.path}/build/sing-box',
  ]) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    candidates.add('$dir/$exe');
    for (final sub in d.listSync().whereType<Directory>()) {
      candidates.add('${sub.path}/$exe');
    }
  }
  candidates.sort((a, b) {
    final am = a.contains(Platform.operatingSystem) ? 0 : 1;
    final bm = b.contains(Platform.operatingSystem) ? 0 : 1;
    return am != bm ? am - bm : a.compareTo(b);
  });
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  try {
    final r = Process.runSync('which', [exe],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    final out = '${r.stdout}'.trim();
    if (r.exitCode == 0 && out.isNotEmpty && File(out).existsSync()) return out;
  } catch (_) {}
  return null;
}

/// 把内核挂到 [ProxyCoreCli.resolveKernelBinary] 查找的位置
/// （`<support>/kernel/sing-box`；flutter test 无 path_provider → 用官方注入点）。
void _installKernel(String bin) {
  final support = Directory.systemTemp.createTempSync('mf_kernel_');
  Directory('${support.path}/kernel').createSync(recursive: true);
  final target =
      '${support.path}/kernel/${Platform.isWindows ? 'sing-box.exe' : 'sing-box'}';
  try {
    Link(target).createSync(bin);
  } catch (_) {
    File(bin).copySync(target);
  }
  LocalPaths.debugSupportDir = () async => support;
}

/// 串行化「独占内核工作目录 + 固定端口」的端到端用例：
/// `flutter test` 默认按文件并发，两个 e2e 文件同时起内核会互相覆盖
/// `ProxyCoreCli.workDir/config.json` 并抢 2080/9090。用跨进程文件锁排队。
Future<T> _withKernelLock<T>(Future<T> Function() body) async {
  final raf = await File('${Directory.systemTemp.path}/mbox_core.e2e.lock')
      .open(mode: FileMode.write);
  try {
    await raf.lock(FileLock.blockingExclusive);
    return await body();
  } finally {
    try {
      await raf.unlock();
    } catch (_) {}
    await raf.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final binary = _findBinary();
  final skip = binary == null
      ? '未找到 sing-box 内核（MBOX_SINGBOX / 仓库 .core_dl / PATH）'
      : null;

  test('端到端：连接设置系统代理 → 断开恢复', skip: skip, () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS 验证系统代理');
      return;
    }
    _installKernel(binary!);
    await _withKernelLock(() async {
      ProxyCoreCli.manageSystemProxy = true; // 本次测试真实管理系统代理
      final core = ProxyCoreCli();
      try {
        final node = ProxyNode(
          tag: '测试节点',
          type: 'vless',
          server: '127.0.0.1',
          port: 9,
          uuid: '00000000-0000-0000-0000-000000000000',
          countryCode: 'HK',
          raw: const {},
        );
        final cfg = SingBoxConfigBuilder.build(
          nodes: [node],
          selectedTag: '测试节点',
          smartMode: true,
          tunMode: 'off',
        );
        // mixed 入站的端口就是系统代理要指向的端口（同一份配置里的 listen_port）
        final mixedIn = (cfg['inbounds'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((i) => i['type'] == 'mixed');
        final port = mixedIn['listen_port'] as int;
        expect(port, 2080, reason: '默认 mixed 端口 2080');

        // 连接 → 系统代理应被设置
        await core.start(cfg);
        expect(core.isRunning, isTrue);
        await Future.delayed(const Duration(milliseconds: 800));
        final proxy = (await Process.run('scutil', ['--proxy'])).stdout as String;
        expect(proxy.contains('HTTPEnable : 1'), isTrue,
            reason: '连接后系统 HTTP 代理应启用\n$proxy');
        expect(proxy.contains('HTTPPort : $port'), isTrue,
            reason: '代理端口应为 $port\n$proxy');

        // 断开 → 系统代理应恢复（关闭）
        await core.stop();
        await Future.delayed(const Duration(milliseconds: 800));
        final after = (await Process.run('scutil', ['--proxy'])).stdout as String;
        expect(after.contains('HTTPEnable : 0'), isTrue,
            reason: '断开后系统代理应恢复关闭\n$after');
        expect(after.contains('HTTPSEnable : 0'), isTrue);
        expect(after.contains('SOCKSEnable : 0'), isTrue);
      } finally {
        // 无论断言成败都确保内核停止 + 代理恢复，避免残留污染环境
        if (core.isRunning) {
          await core.stop();
        }
      }
    });
  }, timeout: const Timeout(Duration(seconds: 90)));
}
