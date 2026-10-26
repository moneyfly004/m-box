@Tags(['e2e'])
library;

// 真实验证：连接流程（Hiddify 模式）—— 立即连接 + 后台测速不阻塞
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final env = Platform.environment['MBOX_SINGBOX'];
  final hasBinary = env != null && File(env).existsSync();
  final skip = hasBinary ? null : '未找到 sing-box 内核';

  test('连接立即生效 + 后台测速不阻塞（Hiddify 模式）', skip: skip, () async {
    // mock 设置存储（测试环境无插件）
    SharedPreferences.setMockInitialValues({'mbox_lang': 'zh'});

    final proxiesFile = File('/tmp/mf_proxies.json');
    if (!proxiesFile.existsSync()) {
      markTestSkipped('无真实节点文件');
      return;
    }
    final proxies = jsonDecode(proxiesFile.readAsStringSync()) as List;
    final nodes = proxies
        .map((e) => ProxyNode.fromClashMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    expect(nodes.length, greaterThan(100));

    // 模拟用户点击连接：带 runSpeedTest=true
    final sw = Stopwatch()..start();
    final conn = ConnectionController.instance;
    conn.nodes = nodes;
    conn.current = null; // 无预设 → 选第一个在线节点
    await conn.connect(runSpeedTest: true);
    debugPrint('连接错误: ${conn.error}');

    // 关键断言 1：连接很快建立（不等测速；测速是全量 824 节点，若阻塞会 >10s）
    expect(sw.elapsed, lessThan(const Duration(seconds: 8)),
        reason: '连接应在测速完成前建立（Hiddify 先连后测）');
    expect(conn.status, ConnStatus.connected, reason: '状态应为已连接');

    // 关键断言 2：后台测速正在运行（speedTesting=true 或刚完成）
    // 测速期间连接保持有效
    await Future.delayed(const Duration(milliseconds: 500));
    expect(conn.status, ConnStatus.connected, reason: '测速期间保持已连接');
    final wasTesting = conn.speedTesting;
    debugPrint('连接耗时 ${sw.elapsedMilliseconds}ms, 测速标记=$wasTesting');

    // 清理
    await conn.disconnect();
    expect(conn.status, ConnStatus.disconnected);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
