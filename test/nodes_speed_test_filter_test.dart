// 节点列表：搜索/筛选后点「测速」，只测筛选出的节点，不测全部。
//
// 回归背景：旧实现无论是否筛选都调用 retestAll → 用户筛出 5 个节点点测速，
// 实际把上千个节点全测一遍，白等且看不到想要的对比结果。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/speed_test_mode.dart';
import 'package:mbox/core/services/speed_tester.dart';
import 'package:mbox/core/services/subscription_service.dart';
import 'package:mbox/l10n/app_strings.dart';
import 'package:mbox/pages/nodes/nodes_page.dart';
import 'package:mbox/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildMBoxTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: ConnectionController.instance),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: child,
      ),
    );

/// 未筛选的节点延迟哨兵值：若它们被「顺手全测」，值会被改写成 -1。
const sentinel = 4321;

ProxyNode _node(String tag, String server, String country) => ProxyNode(
      tag: tag,
      type: 'vless',
      server: server,
      port: 9, // 真实探测被桩替代；端口仅占位
      countryCode: country,
      latencyMs: sentinel,
    )..online = true;

void main() {
  // 被测速的节点 tag（注入桩记录，替代真实 TCP 探测：Windows CI 上连接被
  // 防火墙静默丢弃会跑到 5s 超时，真实探测的用例既慢又不确定）
  late List<String> probed;

  /// 桩的每节点耗时：0 = 立即返回；>0 用来制造"测速进行中"窗口，验证进度显示
  var probeDelayMs = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProxyCoreCli.manageSystemProxy = false;
    // 本文件验证的是「筛选后只测筛选出的节点」+ 进度/并发这些**与测速方式无关**
    // 的行为，用 TCP 探测桩（SpeedTester.debugProbeOverride）注入结果。
    // 这里仍**显式**指定 TCP（而不是依赖默认值）：一旦默认值将来再变，本用例
    // 也不会悄悄改走内核测速——那会去拉真实探测内核（测试环境没有内核二进制
    // → 整轮测速失败、桩一次都不被调用）。内核测速路径由
    // speed_test_mode_test.dart 覆盖。
    ConnectionController.instance.speedTestMode = SpeedTestMode.tcp;
    probed = <String>[];
    probeDelayMs = 0;
    SpeedTester.debugProbeOverride = (node) async {
      probed.add(node.tag);
      if (probeDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: probeDelayMs));
      }
      return 7;
    };
  });
  tearDown(() {
    SpeedTester.debugProbeOverride = null;
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('筛选后再测速：只测筛选出的节点，其余节点状态原样保留', (tester) async {
    final conn = ConnectionController.instance;
    conn.current = null;
    final nodes = [
      _node('日本-01', '127.0.0.1', 'JP'),
      _node('日本-02', '127.0.0.1', 'JP'),
      _node('美国-01', '127.0.0.1', 'US'),
      _node('美国-02', '127.0.0.1', 'US'),
    ];
    await conn.loadNodes(nodes);

    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const NodesPage()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();

    // 搜索「日本」→ 列表只剩 2 个节点
    await tester.enterText(find.byType(TextField).first, '日本');
    // 搜索框有 300ms 防抖（fake timer）：必须 pump 时钟才会真正生效
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 点 ⚡ 测速
    final btn = find.textContaining('⚡');
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    final jp = conn.nodes.where((n) => n.tag.startsWith('日本')).toList();
    final us = conn.nodes.where((n) => n.tag.startsWith('美国')).toList();

    // 筛选出的节点确实被测了，且**只测了它们**
    expect(probed.toSet(), {'日本-01', '日本-02'},
        reason: '筛选后只应测筛选出的节点');
    expect(jp.every((n) => n.latencyMs == 7), true,
        reason: '筛选出的日本节点应被写入新延迟');
    // 未筛选的节点必须原封不动（旧实现会把它们一起测掉 → 变成 -1）
    expect(us.map((n) => n.latencyMs).toList(), everyElement(sentinel),
        reason: '未出现在筛选结果里的节点不该被测速');
    expect(us.every((n) => n.online), true,
        reason: '未测节点不得被标成离线');

    // 列表顺序/内容不受影响：仍是 4 个节点
    expect(conn.nodes, hasLength(4));
  });

  testWidgets('未筛选（搜索框为空）时仍然测速全部节点', (tester) async {
    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([
      _node('香港-01', '127.0.0.1', 'HK'),
      _node('香港-02', '127.0.0.1', 'HK'),
    ]);

    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const NodesPage()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();

    final btn = find.textContaining('⚡');
    await tester.tap(btn);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(probed.toSet(), {'香港-01', '香港-02'},
        reason: '无筛选时应测全部节点');
    expect(conn.nodes.every((n) => n.latencyMs == 7), true);
    // 兜底：本地化文案存在（避免 {n} 占位符漏配导致显示异常）
    expect(AppStrings.t('speed_done_filtered', {'n': '2'}), contains('2'));
  });

  testWidgets('筛选后测速：进度分母是筛选出的节点数（显示 x/N，不是全部）', (tester) async {
    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([
      _node('日本-01', '127.0.0.1', 'JP'),
      _node('日本-02', '127.0.0.1', 'JP'),
      _node('美国-01', '127.0.0.1', 'US'),
      _node('美国-02', '127.0.0.1', 'US'),
      _node('美国-03', '127.0.0.1', 'US'),
    ]);
    probeDelayMs = 400; // 让测速停在"进行中"，好观察进度文案

    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const NodesPage()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '日本');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.textContaining('⚡'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();

    // 筛出 2 个 → 进度必须是 2 的分母（旧实现：要么没有进度、要么按全部 5 个算）
    expect(find.textContaining('/2'), findsOneWidget,
        reason: '筛选后测速进度应为筛选出的节点数');
    expect(find.textContaining('/5'), findsNothing);

    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)));
    await tester.pump();
    expect(probed.toSet(), {'日本-01', '日本-02'});
  });

  test('后台测速正在跑时，用户手动测速必须排队执行而不是被静默丢弃', () async {
    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([
      _node('日本-01', '127.0.0.1', 'JP'),
      _node('日本-02', '127.0.0.1', 'JP'),
      _node('美国-01', '127.0.0.1', 'US'),
      _node('美国-02', '127.0.0.1', 'US'),
    ]);
    probeDelayMs = 150;

    // 后台自动测速（连接后立刻会跑一轮）：占用测速通道
    final background =
        conn.retestAll(switchToBest: false, userInitiated: false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    probed.clear();

    // 用户此时筛选后点测速：旧实现 busy 直接 return → 只弹提示、一个都不测
    final tested = await conn.speedTest(
      tags: {'日本-01', '日本-02'},
      switchToBest: false,
      userInitiated: true,
    );
    await background;

    expect(tested, 2, reason: '手动测速必须真的测到筛选出的节点');
    expect(probed.toSet(), {'日本-01', '日本-02'},
        reason: '只测筛选出的节点，且未被后台测速吃掉');
    // 未筛选的节点保持原延迟（哨兵值），没有被后台那轮的结果覆盖
    expect(
        conn.nodes
            .where((n) => n.tag.startsWith('美国'))
            .every((n) => n.latencyMs == sentinel),
        true);
  });

  test('tags 为空 / 全量标签时行为正确', () async {
    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([
      _node('香港-01', '127.0.0.1', 'HK'),
      _node('香港-02', '127.0.0.1', 'HK'),
    ]);
    probed.clear();
    expect(await conn.speedTest(tags: const <String>{}, userInitiated: true), 0);
    expect(probed, isEmpty);
    expect(
        await conn.speedTest(
            tags: {'香港-01', '香港-02'},
            switchToBest: false,
            userInitiated: true),
        2);
    expect(probed.toSet(), {'香港-01', '香港-02'});
  });
}
