import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/services/subscription_service.dart';

/// 真实订阅配置验证（本机运维用）：读取 /tmp/mf_clash.yaml（真实后端拉取），
/// 用客户端解析器加载节点，验证「核心能加载节点」。
/// 文件不存在时自动跳过，不影响常规 CI。
void main() {
  test('真实 Clash 配置解析（828 节点规模）', () async {
    final f = File('/tmp/mf_clash.yaml');
    if (!f.existsSync()) {
      markTestSkipped('真实配置不存在，跳过（常规 CI）');
      return;
    }
    final raw = f.readAsStringSync();
    final sw = Stopwatch()..start();
    final nodes = SubscriptionService.parseClashYaml(raw);
    sw.stop();
    debugPrint('解析 ${nodes.length} 节点 耗时 ${sw.elapsedMilliseconds}ms');
    expect(nodes.length, greaterThan(0));
    final types = <String, int>{};
    for (final n in nodes) {
      types[n.type] = (types[n.type] ?? 0) + 1;
    }
    debugPrint('类型: ${types.toString()}');
    // 至少覆盖 vless/ss 两种核心协议
    expect(types.containsKey('vless'), isTrue);
    expect(types.containsKey('ss'), isTrue);
    // 无空 server 节点
    expect(nodes.where((n) => n.server.isEmpty || n.port <= 0), isEmpty);
  });
}
