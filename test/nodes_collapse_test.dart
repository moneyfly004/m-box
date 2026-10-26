// 节点列表：国家分组排序（热门置顶）+ 可折叠（默认折叠、仅当前国家展开）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mbox/core/api/api_client.dart';
import 'package:mbox/core/models/models.dart';
import 'package:mbox/core/proxy/proxy_core.dart';
import 'package:mbox/core/proxy/proxy_core_cli.dart';
import 'package:mbox/core/services/account_service.dart';
import 'package:mbox/core/services/subscription_service.dart';
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

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 测试环境禁止真实管理系统代理：stop()→SystemProxyManager.restore()
    // 会 spawn networksetup/scutil 子进程，在 CI/测试机上挂起导致超时
    ProxyCoreCli.manageSystemProxy = false;
  });
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('节点列表：默认折叠（无选中节点时全部收起），点分组头展开该国节点', (tester) async {
    final conn = ConnectionController.instance;
    // 确保无“当前节点”，验证默认全部折叠（直接置 null，不走 resetForLogout→_core.stop）
    conn.current = null;
    await conn.loadNodes([
      ProxyNode(tag: '香港-01', type: 'vless', server: '1.1.1.1', port: 443, countryCode: 'HK', latencyMs: 30),
      ProxyNode(tag: '香港-02', type: 'vless', server: '1.1.1.2', port: 443, countryCode: 'HK', latencyMs: 45),
      ProxyNode(tag: '日本-01', type: 'trojan', server: '2.2.2.1', port: 443, countryCode: 'JP', latencyMs: 88),
    ]);
    for (final n in conn.nodes) {
      n.online = true;
    }
    await _pump(tester, _wrap(const NodesPage()));

    // 分组头始终存在（国名）
    expect(find.text('香港'), findsOneWidget);
    expect(find.text('日本'), findsOneWidget);
    // 默认折叠：节点行隐藏
    expect(find.text('香港-01'), findsNothing);
    expect(find.text('香港-02'), findsNothing);
    expect(find.text('日本-01'), findsNothing);

    // 点香港分组头 → 展开，香港节点可见，日本仍折叠
    await tester.tap(find.text('香港'));
    await tester.pumpAndSettle();
    expect(find.text('香港-01'), findsOneWidget);
    expect(find.text('香港-02'), findsOneWidget);
    expect(find.text('日本-01'), findsNothing);

    // 再点 → 折叠恢复
    await tester.tap(find.text('香港'));
    await tester.pumpAndSettle();
    expect(find.text('香港-01'), findsNothing);
    expect(find.text('香港-02'), findsNothing);
  });

  testWidgets('节点列表：当前节点所在国家默认展开', (tester) async {
    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([
      ProxyNode(tag: '香港-01', type: 'vless', server: '1.1.1.1', port: 443, countryCode: 'HK', latencyMs: 30),
      ProxyNode(tag: '日本-01', type: 'trojan', server: '2.2.2.1', port: 443, countryCode: 'JP', latencyMs: 88),
    ]);
    for (final n in conn.nodes) {
      n.online = true;
    }
    // 选中日本节点（未连接：直接置 current，不走 switchNode→内核/持久化）
    // → 日本默认展开、香港折叠
    conn.current = conn.nodes.firstWhere((n) => n.countryCode == 'JP');
    await _pump(tester, _wrap(const NodesPage()));

    expect(find.text('日本-01'), findsOneWidget); // 当前国家展开
    expect(find.text('香港-01'), findsNothing);   // 其余折叠
  });

  testWidgets('分组顺序：香港(热门)排在日本之前', (tester) async {
    final conn = ConnectionController.instance;
    // 故意乱序加入，验证 UI 排序
    await conn.loadNodes([
      ProxyNode(tag: '日本-01', type: 'trojan', server: '2.2.2.1', port: 443, countryCode: 'JP', latencyMs: 20),
      ProxyNode(tag: '香港-01', type: 'vless', server: '1.1.1.1', port: 443, countryCode: 'HK', latencyMs: 200),
    ]);
    for (final n in conn.nodes) {
      n.online = true;
    }
    await _pump(tester, _wrap(const NodesPage()));

    // 即便日本延迟更低，香港(热门第一)分组头仍在日本之前
    final hkY = tester.getTopLeft(find.text('香港')).dy;
    final jpY = tester.getTopLeft(find.text('日本')).dy;
    expect(hkY < jpY, isTrue, reason: '香港分组应排在日本之前（热门置顶）');
  });
}
