// ignore_for_file: avoid_print, dangling_library_doc_comments, unintended_html_in_doc_comment

/// 运维工具：对真实节点服务器执行自动测速 + 选优 + 手动切换验证（纯 Dart）
/// 用法: dart run tool/speed_test_live.dart <clash.yaml> [--manual 节点名子串]
import 'dart:io';

import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/services/speed_tester.dart';
import 'package:yaml/yaml.dart';

/// 与客户端一致的伪节点过滤
bool isPseudo(ProxyNode n) {
  const markers = ['📢', '⏰', '📱', '💬', '🎯', '🚀', '♻️', '🔯', '🔮', '🛑', '🐟'];
  return markers.any((m) => n.tag.contains(m)) || n.server == 'baidu.com';
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/speed_test_live.dart <clash.yaml> [--manual 名称]');
    exit(1);
  }
  final raw = File(args[0]).readAsStringSync();
  final doc = loadYaml(raw);
  final proxies = (doc as Map)['proxies'] as List;
  final nodes = proxies
      .map((e) => ProxyNode.fromClashMap(Map<String, dynamic>.from(e as Map)))
      .where((n) => n.server.isNotEmpty && n.port > 0 && !isPseudo(n))
      .toList();
  print('节点总数: ${nodes.length}');

  // 自动测速（真实 TCP ping，并发 12）
  print('开始自动测速（TCP ping 真实节点服务器）...');
  final sw = Stopwatch()..start();
  final tester = SpeedTester(connectTimeout: const Duration(seconds: 3));
  final tested = await tester.testAll(nodes, onProgress: (d, t) {
    if (d % 50 == 0 || d == t) stdout.write('\r进度: $d/$t');
  });
  print('\n测速完成: ${sw.elapsed.inSeconds}s, 在线 ${tested.where((n) => n.online).length}/${tested.length}');

  // 自动选择最优节点（客户端同款 selectBest 逻辑）
  final best = SpeedTester.selectBest(tested);
  if (best == null) {
    print('❌ 无可用节点');
    exit(1);
  }
  print('\n🏆 自动选择的最优节点: ${best.tag} | ${best.type} | ${best.server}:${best.port} | ${best.latencyMs}ms | ${best.countryCode}');

  // 延迟排行 Top10
  final sorted = tested.where((n) => n.online).toList()
    ..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
  print('\n延迟 Top10:');
  for (final n in sorted.take(10)) {
    print('  ${n.latencyMs.toString().padLeft(4)}ms  ${n.tag}');
  }

  // 国家聚合（客户端首页快速切换用）
  final byCountry = SpeedTester.bestLatencyByCountry(tested);
  print('\n各国最优延迟: ${byCountry.entries.map((e) => '${e.key}=${e.value}ms').join(' | ')}');

  // 手动切换验证：指定节点名子串 → 单测该节点
  final manual = args.contains('--manual') ? args[args.indexOf('--manual') + 1] : null;
  if (manual != null) {
    final cand = tested.where((n) => n.tag.contains(manual)).toList();
    if (cand.isEmpty) {
      print('\n手动切换: 未找到包含「$manual」的节点');
    } else {
      final ms = await tester.testOne(cand.first);
      print('\n🔧 手动切换: ${cand.first.tag} 延迟 ${ms == -1 ? '不可用' : '$ms ms'}');
    }
  } else {
    // 默认演示手动切换：测 Top1 之外的香港节点
    final hk = tested.where((n) => n.countryCode == 'HK' && n.online).toList()
      ..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    if (hk.isNotEmpty) {
      final target = hk.firstWhere((n) => n.tag != best.tag, orElse: () => hk.first);
      final ms = await tester.testOne(target);
      print('\n🔧 手动切换演示: ${target.tag} 延迟 ${ms == -1 ? '不可用' : '$ms ms'}（与最优 ${best.latencyMs}ms 对比）');
    }
  }
  print('\n✅ 验证完成');
}
