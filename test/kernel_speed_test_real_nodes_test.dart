// ignore_for_file: avoid_print
//
// 真实订阅节点上的**双方式对照**（只读、脱敏输出）。
//
// 运行:
//   MBOX_SINGBOX=$PWD/.core_dl/sing-box-1.14.4-darwin-arm64/sing-box \
//     flutter test test/kernel_speed_test_real_nodes_test.dart --tags e2e --concurrency=1
//
// 目的：在**真实远端节点**（真实机场订阅，含 vless/hysteria2/tuic 等真实协议、
// 真实 emoji 节点名）上确认两件事：
//   1) 可用节点上，TCP 测速与内核测速都能给出合理延迟；
//   2) 两种方式的口径差异是真实存在的（TCP 只有端口握手 → 有一批「TCP 有延迟
//      但内核连不通」的节点，它们才是真正会让用户「显示有延迟却上不了网」的）。
//
// 数据来源：本机 App 缓存里的订阅原文（subscription_cache.json），**只读**。
// 输出**不含**任何节点名 / 服务器 / 凭据 / 订阅地址 —— 只有分协议聚合统计，
// 便于贴进报告而不泄露任何节点信息。
@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/speed_probe_kernel.dart';
import 'package:mbox/core/services/settings_store.dart';
import 'package:mbox/core/services/speed_tester.dart';
import 'package:mbox/core/services/subscription_service.dart';

final _cache = File('${Platform.environment['HOME']}/Library/Application Support/'
    'top.mbox.app/subscription_cache.json');

/// 每类协议最多取几个（控制对远端节点的压力：默认总量 ≤ 12）
const _perType = 4;
const _maxTotal = 12;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('真实节点：TCP 测速 vs 内核测速（脱敏聚合）', () async {
    if (!_cache.existsSync()) {
      markTestSkipped('无本机订阅缓存（${_cache.path}），跳过');
      return;
    }
    final raw = (jsonDecode(_cache.readAsStringSync())
        as Map)['raw']?.toString();
    if (raw == null || raw.isEmpty) {
      markTestSkipped('订阅缓存内容为空，跳过');
      return;
    }
    final all = SubscriptionService.parseClashYaml(raw);
    expect(all, isNotEmpty, reason: '订阅解析应至少产出 1 个节点');
    print('=== 真实节点对照（脱敏） ===');
    print('订阅解析节点总数: ${all.length}');

    // 按协议各取前 N 个（保证覆盖多种协议；顺序取，不做任何筛选）
    final byType = <String, List<ProxyNode>>{};
    for (final n in all) {
      final list = byType.putIfAbsent(n.type, () => <ProxyNode>[]);
      if (list.length < _perType) list.add(n);
    }
    final picked = <ProxyNode>[];
    for (final e in byType.entries) {
      for (final n in e.value) {
        if (picked.length < _maxTotal) picked.add(n);
      }
    }
    print('抽样节点数: ${picked.length}，覆盖协议: ${byType.keys.join(", ")}');
    print('样例节点名是否含需要 URL 编码的字符（emoji/空格/斜杠/中文）: '
        '${picked.where((n) => n.tag.contains(RegExp(r'[^\x20-\x7e]')) || n.tag.contains(" ") || n.tag.contains("/")).length}/${picked.length}');

    // ---------------------------------------------------------- TCP 测速
    print('\n--- TCP 测速（超时 3s）---');
    final tcpSw = Stopwatch()..start();
    final tcp = await SpeedTester(connectTimeout: const Duration(seconds: 3))
        .testAll(picked);
    print('耗时 ${tcpSw.elapsedMilliseconds}ms');
    final tcpOk = tcp.where((n) => mfLatencyUsable(n.latencyMs)).toList();

    // -------------------------------------------------------- 内核测速
    print('\n--- 内核测速（探测内核，超时 5s，探测地址 ${SettingsStore.defaultTestUrl}）---');
    final kSw = Stopwatch()..start();
    await SpeedProbeKernel.instance.ensureStarted(picked);
    final kernelMs = <String, int>{};
    for (final n in picked) {
      kernelMs[n.tag] = await SpeedProbeKernel.instance
          .testDelay(n.tag, timeout: const Duration(seconds: 5));
    }
    print('耗时 ${kSw.elapsedMilliseconds}ms');
    final kOk = picked.where((n) => mfLatencyUsable(kernelMs[n.tag] ?? -1)).toList();

    // ---------------------------------------------------------- 聚合输出
    print('\n=== 聚合结果（不含任何节点名/地址/凭据）===');
    print('TCP 测速成功: ${tcpOk.length}/${picked.length}');
    print('内核测速成功: ${kOk.length}/${picked.length}');
    final bothFail = picked
        .where((n) =>
            !mfLatencyUsable(
                tcp.firstWhere((t) => t.tag == n.tag).latencyMs) &&
            !mfLatencyUsable(kernelMs[n.tag] ?? -1))
        .length;
    final tcpOnlyOk = picked
        .where((n) =>
            mfLatencyUsable(tcp.firstWhere((t) => t.tag == n.tag).latencyMs) &&
            !mfLatencyUsable(kernelMs[n.tag] ?? -1))
        .length;
    final kernelOnlyOk = picked
        .where((n) =>
            !mfLatencyUsable(tcp.firstWhere((t) => t.tag == n.tag).latencyMs) &&
            mfLatencyUsable(kernelMs[n.tag] ?? -1))
        .length;
    print('两种方式都成功: ${picked.length - bothFail - tcpOnlyOk - kernelOnlyOk}');
    print('仅 TCP 成功（内核连不通 → 正是会「显示有延迟却上不了网」的那批）: $tcpOnlyOk');
    print('仅内核成功（UDP-only 协议等裸 TCP 测不了的）: $kernelOnlyOk');
    print('两种都失败: $bothFail');

    final tcpVals = tcpOk.map((n) => n.latencyMs).toList()..sort();
    final kVals = kOk.map((n) => kernelMs[n.tag]!).toList()..sort();
    String range(List<int> v) => v.isEmpty
        ? '（无）'
        : 'min=${v.first}ms p50=${v[v.length ~/ 2]}ms max=${v.last}ms';
    print('TCP 成功延迟分布: ${range(tcpVals)}');
    print('内核成功延迟分布: ${range(kVals)}');

    await SpeedProbeKernel.instance.stop();

    // 断言：抽样里至少要有一个「内核测速也能成功」的节点，否则这台机器的
    // 网络或内核二进制有问题（不是产品逻辑问题），应当让用例显式失败而不是
    // 悄悄「通过」。
    expect(kOk, isNotEmpty,
        reason: '内核测速在真实节点上应当至少成功一个（否则环境异常）');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
