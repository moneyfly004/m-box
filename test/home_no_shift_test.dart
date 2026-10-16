import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/home/home_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

/// 用户反馈：主页每次订阅更新时卡片会移动位置；连接一会儿后国家切换卡片才
/// 临时出现在下方。要求：位置固定、不临时生成卡片、一屏能看到所有卡片。
///
/// 这条用例直接量"卡片纵坐标"：数据到位前后，各卡的 top 必须一致。

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

Map<String, dynamic> _subInfo() => {
      'subscribe_url':
          'https://dy.moneyfly.top/api/v1/client/subscribe?token=t&type=clash',
      'expire_time': '2032-06-06 08:00:00',
      'device_limit': 5,
      'current_devices': 1,
      'remaining_days': 2000,
      'is_expired': false,
      'status': 'active',
    };

/// 订阅内容：nodes 个可用节点（国家码 HK/JP），0 个时是空订阅
String _clashYaml(int nodes) {
  final buf = StringBuffer('proxies:\n');
  for (var i = 0; i < nodes; i++) {
    buf.writeln('  - {name: "N$i", server: ${198}.51.100.${10 + i}, port: 443, '
        'type: ss, password: pw, cipher: aes-128-gcm}');
  }
  return buf.toString();
}

/// 记录型假后端：所有请求本地应答，绝不联网
class _FakeBackend implements HttpClientAdapter {
  _FakeBackend(this.nodes);
  final int nodes;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.path;
    if (path.endsWith('/user/subscribe')) {
      return ResponseBody.fromString(jsonEncode(_env(_subInfo())), 200,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
    }
    if (path.contains('/client/subscribe')) {
      return ResponseBody.fromString(_clashYaml(nodes), 200,
          headers: {Headers.contentTypeHeader: ['text/plain']});
    }
    return ResponseBody.fromString(jsonEncode(_env(null)), 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildMoneyFlyTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
          ChangeNotifierProvider.value(value: ConnectionController.instance),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: child,
      ),
    );

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('订阅刷新前后：各卡片的纵坐标不移动（同步中提示恒定占位）',
      (tester) async {
    ApiClient.debugDio = Dio()..httpClientAdapter = _FakeBackend(3);
    // 先给一批节点，让国家卡片有内容
    final conn = ConnectionController.instance;
    final nodes = <ProxyNode>[
      for (var i = 0; i < 3; i++)
        ProxyNode(
          tag: 'N$i',
          type: 'ss',
          server: '198.51.100.${10 + i}',
          port: 443,
          cipher: 'aes-128-gcm',
          password: 'pw',
          countryCode: i == 0 ? 'HK' : (i == 1 ? 'JP' : 'US'),
          latencyMs: 30 + i * 10,
          online: true,
          raw: const {},
        ),
    ];
    await conn.loadNodes(nodes);
    await _pump(tester, _wrap(const HomePage()));

    double topOf(Finder f) => tester.getTopLeft(f).dy;
    double heightOf(Finder f) => tester.getSize(f).height;

    final chart = find.byType(CustomPaint);
    final header = find.byType(HomePage);
    final beforeChartTop = topOf(chart.first);
    final beforePageHeight = tester.getSize(find.byType(ListView)).height;

    // 模拟"订阅刷新"：进入同步中状态（旧实现这里会插一整块内容 → 下方卡片位移）
    conn.setSyncingForTest(true);
    await tester.pump();
    expect(topOf(chart.first), beforeChartTop,
        reason: '同步中提示不许改变下方卡片位置（旧实现整块增删导致位移）');
    expect(tester.getSize(find.byType(ListView)).height, beforePageHeight,
        reason: '页面高度也不该因为同步提示变化');

    conn.setSyncingForTest(false);
    await tester.pump();
    expect(topOf(chart.first), beforeChartTop);
    expect(heightOf(header), greaterThan(0));
  });

  testWidgets('国家切换卡片始终占位：没有测速数据时也渲染（不临时生成）',
      (tester) async {
    ApiClient.debugDio = Dio()..httpClientAdapter = _FakeBackend(0);
    final conn = ConnectionController.instance;
    // 空节点（冷启动 / 刚连接还没测出国家）
    await conn.loadNodes(const []);
    await _pump(tester, _wrap(const HomePage()));

    expect(find.byKey(const ValueKey('quick_countries')), findsOneWidget,
        reason: '国家切换区块必须始终渲染（骨架占位），不能等数据到位才出现');
    expect(find.byKey(const ValueKey('quick_row_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick_row_1')), findsOneWidget);
  });
}
