// 验证测速 FD 不泄漏：测速前后打开的文件描述符数量应基本不变
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/services/speed_tester.dart';

int _fdCount() {
  // macOS 无 /dev/fd 挂载：用 lsof 统计自身进程的 FD 数
  try {
    final r = Process.runSync('lsof', ['-p', '$pid', '-F', 'f'],
        runInShell: true);
    return (r.stdout as String).split('\n').where((l) => l.startsWith('f')).length;
  } catch (_) {
    return -1;
  }
}

void main() {
  test('测速后 FD 不堆积（destroy 释放）', () async {
    if (!Platform.isMacOS && !Platform.isLinux) {
      markTestSkipped('仅 Unix 可查 FD');
      return;
    }
    // 构造 30 个真实地址节点（含不可达的，模拟真实测速路径）
    final nodes = <ProxyNode>[
      for (var i = 0; i < 30; i++)
        ProxyNode(
          tag: '节点$i',
          type: 'vless',
          server: i.isEven ? '127.0.0.1' : '203.0.113.$i', // 本地可达 + 保留地址不可达
          port: i.isEven ? 9 : 80, // 9=拒绝快速失败
          uuid: '00000000-0000-0000-0000-000000000000',
          countryCode: 'XX',
          raw: const {},
        ),
    ];
    // 预热（让 Dart 运行时稳定）
    await SpeedTester.instance.testAll(nodes);
    await Future.delayed(const Duration(milliseconds: 300));
    final before = _fdCount();
    // 真实测速 3 轮（3 次 probe × 30 节点 = 90 次连接）
    for (var round = 0; round < 3; round++) {
      await SpeedTester.instance.testAll(nodes);
    }
    await Future.delayed(const Duration(milliseconds: 500));
    final after = _fdCount();
    expect((after - before).abs(), lessThan(50),
        reason: '测速不应堆积 FD（泄漏会很快超过限制）');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
